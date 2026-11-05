use anyhow::{Context, ensure};
use objc2::{
    msg_send,
    rc::{Allocated, Retained},
    runtime::{AnyClass, AnyObject},
};
use objc2_foundation::{NSBundle, NSError, NSString};

pub struct Updater {
    _framework: Retained<NSBundle>,
    _controller: Retained<AnyObject>,
    updater: Retained<AnyObject>,
}
impl Updater {
    pub fn start() -> anyhow::Result<Self> {
        Self::initialize(true)
    }
    pub fn smoke() -> anyhow::Result<()> {
        let mtm = objc2::MainThreadMarker::new().context("Smoke probe must run on main thread")?;
        let _app = objc2_app_kit::NSApplication::sharedApplication(mtm);
        let _runtime = Self::initialize(false)?;
        Ok(())
    }
    fn initialize(start: bool) -> anyhow::Result<Self> {
        ensure!(
            objc2::MainThreadMarker::new().is_some(),
            "Sparkle must start on the main thread"
        );
        let bundle = NSBundle::mainBundle();
        ensure!(
            bundle
                .bundleIdentifier()
                .is_some_and(|id| id.to_string() == "xyz.ipocket.MijiaLAN.Rust"),
            "Not a release Rust app bundle"
        );
        let platform = if cfg!(target_arch = "aarch64") {
            "macos-arm64"
        } else {
            "macos-x86_64"
        };
        for (key, expected) in [
            ("SUFeedURL", super::feed_url(platform)),
            ("SUPublicEDKey", super::PUBLIC_KEY.into()),
        ] {
            let actual: Option<Retained<NSString>> = unsafe {
                msg_send![&*bundle, objectForInfoDictionaryKey: &*NSString::from_str(key)]
            };
            ensure!(
                actual.is_some_and(|value| value.to_string() == expected),
                "Unexpected {key}"
            );
        }
        let path = bundle
            .privateFrameworksPath()
            .context("Missing Frameworks directory")?
            .stringByAppendingPathComponent(&NSString::from_str("Sparkle.framework"));
        let framework = NSBundle::bundleWithPath(&path).context("Missing bundled Sparkle")?;
        unsafe { framework.loadAndReturnError() }.context("Unable to load bundled Sparkle")?;
        let class =
            AnyClass::get(c"SPUStandardUpdaterController").context("Missing Sparkle controller")?;
        // Messages match Sparkle's pinned public Objective-C headers. Both objects outlive all panels.
        let (controller, updater) = unsafe {
            let allocated: Allocated<AnyObject> = msg_send![class, alloc];
            let controller: Retained<AnyObject> = msg_send![allocated,
                initWithStartingUpdater: false,
                updaterDelegate: Option::<&AnyObject>::None,
                userDriverDelegate: Option::<&AnyObject>::None];
            let updater: Retained<AnyObject> = msg_send![&*controller, updater];
            let mut error: *mut NSError = std::ptr::null_mut();
            let started = !start || msg_send![&*updater, startUpdater: &mut error];
            if !started {
                let message = error
                    .as_ref()
                    .map(|e| e.localizedDescription().to_string())
                    .unwrap_or_default();
                anyhow::bail!("Could not start Sparkle: {message}");
            }
            (controller, updater)
        };
        Ok(Self {
            _framework: framework,
            _controller: controller,
            updater,
        })
    }
    pub fn can_check(&self) -> bool {
        unsafe { msg_send![&*self.updater, canCheckForUpdates] }
    }
    pub fn automatically_checks(&self) -> bool {
        unsafe { msg_send![&*self.updater, automaticallyChecksForUpdates] }
    }
    pub fn set_automatically_checks(&self, enabled: bool) {
        unsafe {
            let _: () = msg_send![&*self.updater, setAutomaticallyChecksForUpdates: enabled];
        }
    }
    pub fn check(&self) {
        if self.can_check() {
            if let Some(mtm) = objc2::MainThreadMarker::new() {
                #[allow(deprecated)]
                objc2_app_kit::NSApplication::sharedApplication(mtm)
                    .activateIgnoringOtherApps(true);
            }
            unsafe {
                let _: () = msg_send![&*self.updater, checkForUpdates];
            }
        }
    }
}
