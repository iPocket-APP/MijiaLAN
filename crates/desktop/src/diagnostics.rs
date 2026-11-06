//! Application-owned export tasks survive panel dismissal and never send mail automatically.
use gpui::{App, Global};
use mijialan_core::{Engine, localization::text as t};
use mijialan_homekit::{
    HomeKit,
    diagnostics::{ApplicationInfo, report, suggested_name, write_report},
};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::SystemTime,
};

pub const SUPPORT_ADDRESS: &str = "contact@ipocket.xyz";

#[derive(Clone, Debug, Default)]
pub enum ExportState {
    #[default]
    Idle,
    Collecting,
    Exported(PathBuf),
    Failed(String),
}
#[derive(Clone)]
pub struct Diagnostics {
    state: Arc<Mutex<ExportState>>,
    engine: Arc<Engine>,
    bridge: Arc<HomeKit>,
}
impl Global for Diagnostics {}
impl Diagnostics {
    pub fn new(engine: Arc<Engine>, bridge: Arc<HomeKit>) -> Self {
        Self {
            state: Arc::new(Mutex::new(ExportState::Idle)),
            engine,
            bridge,
        }
    }
    pub fn state(&self) -> ExportState {
        self.state.lock().unwrap().clone()
    }
    pub fn collecting(&self) -> bool {
        matches!(self.state(), ExportState::Collecting)
    }
    pub fn subtitle(&self) -> String {
        match self.state() {
            ExportState::Idle => {
                t("反馈问题时附上。包含设备名称和读数，不含 Token、IP 地址和配对信息。")
            }
            ExportState::Collecting => t("正在读取每台设备…"),
            ExportState::Exported(path) => format!(
                "{} {}",
                t("已保存"),
                path.file_name().unwrap_or_default().to_string_lossy()
            ),
            ExportState::Failed(error) => format!("{} {error}", t("导出失败：")),
        }
    }
    fn begin(&self) -> bool {
        let mut state = self.state.lock().unwrap();
        if matches!(*state, ExportState::Collecting) {
            return false;
        }
        *state = ExportState::Collecting;
        true
    }
}

pub fn logs_directory() -> anyhow::Result<PathBuf> {
    #[cfg(target_os = "macos")]
    return directories::BaseDirs::new()
        .map(|base| base.home_dir().join("Library/Logs/MijiaLAN Rust"))
        .ok_or_else(|| anyhow::anyhow!("Cannot locate the user log directory"));
    #[cfg(not(target_os = "macos"))]
    directories::ProjectDirs::from("xyz", "iPocket", "MijiaLAN Rust")
        .map(|project| project.data_local_dir().join("Logs"))
        .ok_or_else(|| anyhow::anyhow!("Cannot locate the user log directory"))
}

pub fn application_info() -> ApplicationInfo {
    #[allow(unused_mut)]
    let mut info = ApplicationInfo::default();
    #[cfg(target_os = "macos")]
    {
        use objc2::{msg_send, rc::Retained};
        use objc2_foundation::{NSBundle, NSProcessInfo, NSString};
        let bundle = NSBundle::mainBundle();
        for (key, field) in [
            ("CFBundleShortVersionString", &mut info.version),
            ("CFBundleVersion", &mut info.build),
        ] {
            let value: Option<Retained<NSString>> = unsafe {
                msg_send![&*bundle, objectForInfoDictionaryKey: &*NSString::from_str(key)]
            };
            if let Some(value) = value {
                *field = value.to_string();
            }
        }
        info.os_version = NSProcessInfo::processInfo()
            .operatingSystemVersionString()
            .to_string();
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(file) = std::env::current_exe()
            .ok()
            .and_then(|exe| {
                exe.parent()
                    .map(|parent| parent.join("mijialan-update.json"))
            })
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
        {
            info.build = file["build"]
                .as_u64()
                .map(|value| value.to_string())
                .unwrap_or_default();
        }
    }
    info
}

pub fn mailto_url(subject: &str, body: &str) -> url::Url {
    let mut url =
        url::Url::parse(&format!("mailto:{SUPPORT_ADDRESS}")).expect("fixed support address");
    url.query_pairs_mut()
        .append_pair("subject", subject)
        .append_pair("body", body);
    // mailto uses URI encoding (RFC 6068), not form encoding: spaces must be %20.
    // Literal plus signs have already become %2B and remain intact.
    let query = url.query().map(|query| query.replace('+', "%20"));
    url.set_query(query.as_deref());
    url
}

#[cfg(target_os = "macos")]
fn compose_with_attachment(path: &Path, subject: &str, body: &str) -> bool {
    use objc2::runtime::AnyObject;
    use objc2_app_kit::{NSSharingService, NSSharingServiceNameComposeEmail};
    use objc2_foundation::{NSArray, NSString, NSURL};
    if objc2::MainThreadMarker::new().is_none() {
        return false;
    }
    let Some(service) =
        NSSharingService::sharingServiceNamed(unsafe { NSSharingServiceNameComposeEmail })
    else {
        return false;
    };
    let body = NSString::from_str(body);
    let file = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
    let items = NSArray::<AnyObject>::from_slice(&[&body, &file]);
    // Both items implement NSPasteboardWriting, as required by NSSharingService.
    if !unsafe { service.canPerformWithItems(Some(&items)) } {
        return false;
    }
    let recipient = NSString::from_str(SUPPORT_ADDRESS);
    service.setRecipients(Some(&NSArray::from_slice(&[&*recipient])));
    service.setSubject(Some(&NSString::from_str(subject)));
    unsafe {
        service.performWithItems(&items);
    }
    true
}

fn deliver(path: &Path, email: bool, info: &ApplicationInfo, cx: &mut App) {
    if email {
        let subject = format!(
            "MijiaLAN Rust {} ({}) · {}",
            info.version,
            info.build,
            t("诊断信息")
        );
        let body = t("请描述遇到的问题，例如哪台设备在家庭中显示警告：");
        #[cfg(target_os = "macos")]
        if compose_with_attachment(
            path,
            &subject,
            &format!("{body}\n\n{}", t("诊断文件已作为附件添加。")),
        ) {
            return;
        }
        let body = format!(
            "{body}\n\n{}\n{}",
            t("请手动添加刚导出的诊断文件："),
            path.display()
        );
        cx.open_url(mailto_url(&subject, &body).as_str());
    }
    cx.reveal_path(path);
}

pub fn reveal(cx: &mut App) {
    if let ExportState::Exported(path) = cx.global::<Diagnostics>().state() {
        cx.reveal_path(&path);
    }
}

pub fn export(cx: &mut App, email: bool) {
    let diagnostics = cx.global::<Diagnostics>().clone();
    let info = application_info();
    if email
        && let ExportState::Exported(path) = diagnostics.state()
        && path.is_file()
    {
        deliver(&path, true, &info, cx);
        return;
    }
    if !diagnostics.begin() {
        return;
    }
    cx.refresh_windows();
    let engine = diagnostics.engine.clone();
    let bridge = diagnostics.bridge.clone();
    let metadata = info.clone();
    cx.spawn(async move |cx| {
        let result = cx
            .background_executor()
            .spawn(async move {
                engine.refresh_all();
                let now = SystemTime::now();
                let value = report(&engine, &bridge, &metadata, now);
                let path = logs_directory()?.join(suggested_name(now));
                write_report(&path, &value)
            })
            .await;
        let _ = cx.update(|cx| {
            match result {
                Ok(path) => {
                    *diagnostics.state.lock().unwrap() = ExportState::Exported(path.clone());
                    deliver(&path, email, &info, cx);
                }
                Err(error) => {
                    *diagnostics.state.lock().unwrap() = ExportState::Failed(
                        mijialan_homekit::diagnostics::redact(&error.to_string()),
                    )
                }
            }
            cx.refresh_windows();
        });
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn report_ownership_is_independent_of_a_panel_and_prevents_duplicate_exports() {
        let engine = Arc::new(Engine::demo());
        let service = Diagnostics::new(engine.clone(), Arc::new(HomeKit::new(engine)));
        let retained = service.clone();
        assert!(service.begin());
        assert!(!retained.begin());
        drop(service);
        assert!(retained.collecting());
        *retained.state.lock().unwrap() = ExportState::Exported("report.json".into());
        assert!(matches!(retained.state(), ExportState::Exported(_)));
    }
    #[test]
    fn mail_fallback_preserves_recipient_unicode_ampersands_and_newlines() {
        let subject = "诊断信息 · Rust 0.1.0+hotfix (12)";
        let body = "请描述问题：\n\n诊断文件 & 附件 + 补充";
        let url = mailto_url(subject, body);
        assert_eq!(url.scheme(), "mailto");
        assert_eq!(url.path(), SUPPORT_ADDRESS);
        let query: std::collections::BTreeMap<_, _> = url.query_pairs().into_owned().collect();
        assert_eq!(query["subject"], subject);
        assert_eq!(query["body"], body);
        assert!(!url.as_str().contains(' '));
        assert!(!url.as_str().contains('+'));
        assert!(url.as_str().contains("%20") && url.as_str().contains("%2B"));
    }
}
