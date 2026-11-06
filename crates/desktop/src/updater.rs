//! One updater for the process lifetime, independent of transient tray panels.
#[cfg(target_os = "macos")]
#[path = "updater/macos.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "updater/windows.rs"]
mod platform;

use gpui::{App, Global};
use mijialan_core::localization::text as t;

pub const ORIGIN: &str = env!("MIJIALAN_UPDATE_ORIGIN");
pub const PUBLIC_KEY: &str = env!("MIJIALAN_UPDATE_PUBLIC_KEY");

pub fn feed_url(platform: &str) -> String {
    format!("{ORIGIN}/rs/{platform}/appcast.xml")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpdateNotice {
    pub version: Option<String>,
}
impl UpdateNotice {
    pub fn label(&self) -> String {
        self.version
            .as_ref()
            .map(|version| format!("{} {version}", t("更新至")))
            .unwrap_or_else(|| t("发现新版本"))
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Presentation {
    pub can_check: bool,
    pub automatic_checks: bool,
    pub automatic_downloads: Option<bool>,
    pub notice: Option<UpdateNotice>,
}

pub struct Updater {
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    runtime: Option<platform::Updater>,
    reason: String,
}
impl Global for Updater {}
impl Updater {
    pub fn start(demo: bool) -> Self {
        if disabled(demo, |name| std::env::var(name).ok()) {
            return Self::unavailable(t("演示和预览模式不检查更新"));
        }
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        match platform::Updater::start() {
            Ok(runtime) => Self {
                runtime: Some(runtime),
                reason: String::new(),
            },
            Err(error) => {
                eprintln!("Rust updater unavailable: {error:#}");
                Self::unavailable(t("请安装正式发布包以启用自动更新"))
            }
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        Self::unavailable(t("此平台暂不支持应用内更新"))
    }
    fn unavailable(reason: String) -> Self {
        Self {
            #[cfg(any(target_os = "macos", target_os = "windows"))]
            runtime: None,
            reason,
        }
    }
    pub fn enabled(&self) -> bool {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        return self.runtime.is_some();
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        false
    }
    pub fn can_check(&self) -> bool {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        return self
            .runtime
            .as_ref()
            .is_some_and(|updater| updater.can_check());
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        false
    }
    pub fn automatically_checks(&self) -> bool {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        return self
            .runtime
            .as_ref()
            .is_some_and(|updater| updater.automatically_checks());
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        false
    }
    pub fn set_automatically_checks(&self, enabled: bool) {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        if let Some(runtime) = &self.runtime {
            runtime.set_automatically_checks(enabled);
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        let _ = enabled;
    }
    pub fn reason(&self) -> &str {
        &self.reason
    }
    pub fn available(&self) -> Option<UpdateNotice> {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        return self
            .runtime
            .as_ref()
            .and_then(|updater| updater.available());
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        None
    }
    pub fn check_label(&self) -> String {
        if self.available().is_some() {
            t("查看更新…")
        } else {
            t("检查更新…")
        }
    }
    pub fn automatically_downloads(&self) -> Option<bool> {
        #[cfg(target_os = "macos")]
        return self
            .runtime
            .as_ref()
            .map(|updater| updater.automatically_downloads());
        #[cfg(not(target_os = "macos"))]
        None
    }
    pub fn set_automatically_downloads(&self, enabled: bool) {
        #[cfg(target_os = "macos")]
        if let Some(runtime) = &self.runtime {
            runtime.set_automatically_downloads(enabled);
        }
        #[cfg(not(target_os = "macos"))]
        let _ = enabled;
    }
    pub fn presentation(&self) -> Presentation {
        Presentation {
            can_check: self.can_check(),
            automatic_checks: self.automatically_checks(),
            automatic_downloads: self.automatically_downloads(),
            notice: self.available(),
        }
    }
    pub fn check(&self) {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        if let Some(runtime) = &self.runtime {
            runtime.check();
        }
    }
}

pub fn check(cx: &mut App) {
    if cx.has_global::<Updater>() {
        cx.global::<Updater>().check();
    }
}

/// Package validation loads the real runtime and metadata without starting a check,
/// reading device credentials, opening a bridge, or changing updater preferences.
pub fn smoke() -> anyhow::Result<()> {
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    return platform::Updater::smoke();
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    anyhow::bail!("Updater smoke probe is only available on macOS and Windows")
}

#[cfg(target_os = "windows")]
pub fn take_shutdown_request() -> bool {
    platform::take_shutdown_request()
}

fn disabled(demo: bool, env: impl Fn(&str) -> Option<String>) -> bool {
    demo || [
        "MIJIALAN_UI_PREVIEW",
        "MIJIALAN_EPHEMERAL",
        "MIJIALAN_DISABLE_UPDATES",
    ]
    .iter()
    .any(|key| env(key).as_deref() == Some("1"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn feeds_are_isolated_by_flavor_platform_and_architecture() {
        use base64::Engine as _;
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(PUBLIC_KEY)
                .unwrap()
                .len(),
            32
        );
        let feeds: std::collections::BTreeSet<_> =
            ["macos-arm64", "macos-x86_64", "windows-x86_64"]
                .map(feed_url)
                .into_iter()
                .collect();
        assert_eq!(feeds.len(), 3);
        assert!(
            feeds
                .iter()
                .all(|url| url.starts_with("https://mijialan-updates.ipocket.xyz/rs/"))
        );
        assert!(!feeds.contains(&format!("{ORIGIN}/appcast.xml")));
    }
    #[test]
    fn smoke_and_demo_modes_never_initialize_an_updater() {
        assert!(disabled(true, |_| None));
        assert!(!disabled(false, |_| None));
        for name in [
            "MIJIALAN_UI_PREVIEW",
            "MIJIALAN_EPHEMERAL",
            "MIJIALAN_DISABLE_UPDATES",
        ] {
            assert!(disabled(false, |key| (key == name).then(|| "1".into())));
        }
    }
}
