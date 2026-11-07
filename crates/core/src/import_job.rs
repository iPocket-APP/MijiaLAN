//! Login lifetime is independent of a popup view; hiding the menu-bar panel never cancels an import.
use crate::{Engine, cloud};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};

#[derive(Clone)]
pub enum Progress {
    Idle,
    Fetching,
    Waiting(cloud::Ticket),
    Importing,
    Done(String),
    Failed(String),
}
struct State {
    generation: u64,
    cancel: Arc<AtomicBool>,
    progress: Progress,
}
pub struct ImportJob(Mutex<State>);
impl Default for ImportJob {
    fn default() -> Self {
        Self(Mutex::new(State {
            generation: 0,
            cancel: Arc::new(AtomicBool::new(false)),
            progress: Progress::Idle,
        }))
    }
}
impl ImportJob {
    pub fn snapshot(&self) -> Progress {
        self.0.lock().unwrap().progress.clone()
    }
    pub fn busy(&self) -> bool {
        matches!(
            self.snapshot(),
            Progress::Fetching | Progress::Waiting(_) | Progress::Importing
        )
    }
    pub fn cancel(&self) {
        let mut state = self.0.lock().unwrap();
        state.cancel.store(true, Ordering::Relaxed);
        state.generation += 1;
        state.progress = Progress::Idle;
    }
    fn set(&self, generation: u64, progress: Progress) {
        let mut state = self.0.lock().unwrap();
        if generation == state.generation {
            state.progress = progress;
        }
    }
    pub fn take_finished(&self) -> Option<std::result::Result<String, String>> {
        let mut state = self.0.lock().unwrap();
        let result = match &state.progress {
            Progress::Done(text) => Some(Ok(text.clone())),
            Progress::Failed(error) => Some(Err(error.clone())),
            _ => None,
        };
        if result.is_some() {
            state.progress = Progress::Idle;
        }
        result
    }
    pub fn start(self: &Arc<Self>, engine: Arc<Engine>, region: String) {
        self.start_with_default(engine, region, true);
    }

    #[cfg(target_os = "linux")]
    pub fn start_unbridged(self: &Arc<Self>, engine: Arc<Engine>, region: String) {
        self.start_with_default(engine, region, false);
    }

    fn start_with_default(self: &Arc<Self>, engine: Arc<Engine>, region: String, bridged: bool) {
        if engine.is_demo() {
            self.0.lock().unwrap().progress =
                Progress::Failed("请启动正式模式后扫码导入设备".into());
            return;
        }
        let (generation, cancel) = {
            let mut state = self.0.lock().unwrap();
            state.cancel.store(true, Ordering::Relaxed);
            state.generation += 1;
            state.cancel = Arc::new(AtomicBool::new(false));
            state.progress = Progress::Fetching;
            (state.generation, state.cancel.clone())
        };
        let job = self.clone();
        std::thread::spawn(move || {
            let result = (|| -> crate::Result<String> {
                #[cfg(target_os = "linux")]
                engine.store.vault.prepare_credentials().map_err(|error| {
                    let hint = if crate::localization::english() {
                        "Start and unlock Secret Service in your desktop session, then retry the import."
                    } else {
                        "请在桌面会话中启动并解锁 Secret Service（如 GNOME Keyring 或 KeePassXC），再重试导入。"
                    };
                    crate::Error::Storage(format!("{hint}\n{error}"))
                })?;
                if cancel.load(Ordering::Relaxed) {
                    return Ok("导入已取消".into());
                }
                let ticket = cloud::start()?;
                if cancel.load(Ordering::Relaxed) {
                    return Ok("导入已取消".into());
                }
                job.set(generation, Progress::Waiting(ticket.clone()));
                let session = cloud::wait(&ticket, &region, &cancel)?;
                job.set(generation, Progress::Importing);
                let report = session.import_with_default(&engine, &cancel, bridged)?;
                Ok(if crate::localization::english() {
                    format!(
                        "Imported {} devices from {}; skipped {} without LAN credentials",
                        report.imported,
                        report.region,
                        report.skipped.len()
                    )
                } else {
                    format!(
                        "已从 {} 导入 {} 台设备，跳过 {} 台无局域网凭据的设备",
                        report.region,
                        report.imported,
                        report.skipped.len()
                    )
                })
            })();
            job.set(
                generation,
                match result {
                    Ok(text) => Progress::Done(text),
                    Err(error) => Progress::Failed(error.to_string()),
                },
            );
        });
    }
}
