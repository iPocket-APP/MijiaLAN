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
    session_to_remember: Option<cloud::Session>,
    saved_region: Option<String>,
    saved_revision: u64,
}

enum Login {
    Scan {
        region: String,
        offer_remember: bool,
    },
    Saved,
}
pub struct ImportJob(Mutex<State>);
impl Default for ImportJob {
    fn default() -> Self {
        Self(Mutex::new(State {
            generation: 0,
            cancel: Arc::new(AtomicBool::new(false)),
            progress: Progress::Idle,
            session_to_remember: None,
            saved_region: None,
            saved_revision: 0,
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
        state.session_to_remember = None;
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
        self.start_with_default(
            engine,
            Login::Scan {
                region,
                offer_remember: true,
            },
            true,
        );
    }

    #[cfg(target_os = "linux")]
    pub fn start_unbridged(self: &Arc<Self>, engine: Arc<Engine>, region: String) {
        self.start_with_default(
            engine,
            Login::Scan {
                region,
                offer_remember: false,
            },
            false,
        );
    }

    pub fn reimport(self: &Arc<Self>, engine: Arc<Engine>) {
        self.start_with_default(engine, Login::Saved, true);
    }

    pub fn can_remember(&self) -> bool {
        self.0.lock().unwrap().session_to_remember.is_some()
    }

    pub fn saved_region(&self) -> Option<String> {
        self.0.lock().unwrap().saved_region.clone()
    }

    pub fn load_remembered(&self, engine: &Engine) -> crate::Result<()> {
        if engine.is_demo() {
            return Ok(());
        }
        let saved_revision = self.0.lock().unwrap().saved_revision;
        let session = cloud::Session::load(&engine.store.vault)?;
        let mut state = self.0.lock().unwrap();
        if state.saved_revision == saved_revision {
            state.saved_region = session.map(|login| login.region().to_owned());
        }
        Ok(())
    }

    pub fn remember(&self, engine: &Engine) -> crate::Result<()> {
        let mut state = self.0.lock().unwrap();
        if let Some(session) = &state.session_to_remember {
            session.remember(&engine.store.vault)?;
            state.saved_region = Some(session.region().to_owned());
            state.session_to_remember = None;
            state.saved_revision += 1;
            state.progress = Progress::Done(if crate::localization::english() {
                "Xiaomi Home login saved".into()
            } else {
                "米家登录已保存".into()
            });
        }
        Ok(())
    }

    pub fn forget(&self, engine: &Engine) -> crate::Result<()> {
        let mut state = self.0.lock().unwrap();
        cloud::Session::forget(&engine.store.vault)?;
        state.cancel.store(true, Ordering::Relaxed);
        state.generation += 1;
        state.saved_region = None;
        state.saved_revision += 1;
        state.session_to_remember = None;
        state.progress = Progress::Idle;
        Ok(())
    }

    fn start_with_default(self: &Arc<Self>, engine: Arc<Engine>, login: Login, bridged: bool) {
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
            state.session_to_remember = None;
            state.progress = if matches!(login, Login::Saved) {
                Progress::Importing
            } else {
                Progress::Fetching
            };
            (state.generation, state.cancel.clone())
        };
        let job = self.clone();
        std::thread::spawn(move || {
            let is_saved = matches!(login, Login::Saved);
            let result = (|| -> crate::Result<(String, Option<cloud::Session>)> {
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
                    return Err(crate::Error::Validation("导入已取消".into()));
                }
                let (mut session, offer_remember) = match login {
                    Login::Saved => (
                        cloud::Session::load(&engine.store.vault)?
                            .ok_or(crate::Error::CloudSessionExpired)?,
                        false,
                    ),
                    Login::Scan {
                        region,
                        offer_remember,
                    } => {
                        let ticket = cloud::start()?;
                        if cancel.load(Ordering::Relaxed) {
                            return Err(crate::Error::Validation("导入已取消".into()));
                        }
                        job.set(generation, Progress::Waiting(ticket.clone()));
                        (cloud::wait(&ticket, &region, &cancel)?, offer_remember)
                    }
                };
                job.set(generation, Progress::Importing);
                let report = session.import_with_default(&engine, &cancel, bridged, !is_saved)?;
                session.set_region(report.region.clone());
                let summary = if crate::localization::english() {
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
                };
                Ok((summary, offer_remember.then_some(session)))
            })();
            let mut state = job.0.lock().unwrap();
            if state.generation != generation {
                return;
            }
            state.progress = match result {
                Ok((text, session)) => {
                    state.session_to_remember = session;
                    Progress::Done(text)
                }
                Err(crate::Error::CloudSessionExpired) if is_saved => {
                    state.saved_region = None;
                    state.saved_revision += 1;
                    let error = crate::Error::CloudSessionExpired.to_string();
                    let message = match cloud::Session::forget(&engine.store.vault) {
                        Ok(()) => error,
                        Err(storage) => format!("{error}\n{storage}"),
                    };
                    Progress::Failed(message)
                }
                Err(error) => Progress::Failed(error.to_string()),
            };
        });
    }
}
