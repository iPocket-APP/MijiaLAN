use anyhow::{Context, ensure};
use objc2::{
    DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send,
    rc::{Allocated, Retained},
    runtime::{AnyClass, AnyObject},
    sel,
};
use objc2_foundation::{NSBundle, NSError, NSObject, NSObjectProtocol, NSString};
use std::cell::RefCell;

#[derive(Default)]
struct ReminderState {
    version: RefCell<Option<String>>,
}

define_class!(
    // Sparkle is loaded at runtime; these selectors match its pinned public headers.
    // The standard driver calls them on the main thread and tests respondsToSelector:.
    #[unsafe(super = NSObject)]
    #[thread_kind = MainThreadOnly]
    #[ivars = ReminderState]
    struct MijiaLANRustUpdateDelegate;

    unsafe impl NSObjectProtocol for MijiaLANRustUpdateDelegate {}

    impl MijiaLANRustUpdateDelegate {
        #[unsafe(method(supportsGentleScheduledUpdateReminders))]
        fn supports_gentle_reminders(&self) -> bool { true }

        #[unsafe(method(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:))]
        fn should_show(&self, _update: &AnyObject, immediate_focus: bool) -> bool {
            immediate_focus
        }

        #[unsafe(method(standardUserDriverWillHandleShowingUpdate:forUpdate:state:))]
        fn will_show(&self, _handle: bool, update: &AnyObject, _state: &AnyObject) {
            let version: Retained<NSString> = unsafe { msg_send![update, displayVersionString] };
            *self.ivars().version.borrow_mut() = Some(version.to_string());
        }

        #[unsafe(method(standardUserDriverDidReceiveUserAttentionForUpdate:))]
        fn received_attention(&self, _update: &AnyObject) {
            self.ivars().version.borrow_mut().take();
        }

        #[unsafe(method(standardUserDriverWillFinishUpdateSession))]
        fn finished(&self) {
            self.ivars().version.borrow_mut().take();
        }
    }
);

pub struct Updater {
    _framework: Retained<NSBundle>,
    _controller: Retained<AnyObject>,
    updater: Retained<AnyObject>,
    delegate: Retained<MijiaLANRustUpdateDelegate>,
}
impl Updater {
    pub fn start() -> anyhow::Result<Self> {
        Self::initialize(true)
    }
    pub fn smoke() -> anyhow::Result<()> {
        let mtm = objc2::MainThreadMarker::new().context("Smoke probe must run on main thread")?;
        let _app = objc2_app_kit::NSApplication::sharedApplication(mtm);
        let runtime = Self::initialize(false)?;
        let gentle: bool =
            unsafe { msg_send![&*runtime.delegate, supportsGentleScheduledUpdateReminders] };
        ensure!(gentle, "Missing gentle reminders");
        for selector in [
            sel!(automaticallyDownloadsUpdates),
            sel!(setAutomaticallyDownloadsUpdates:),
        ] {
            let responds: bool =
                unsafe { msg_send![&*runtime.updater, respondsToSelector: selector] };
            ensure!(responds, "Missing Sparkle download preferences");
        }
        Ok(())
    }
    fn initialize(start: bool) -> anyhow::Result<Self> {
        let mtm = MainThreadMarker::new().context("Sparkle must start on the main thread")?;
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
        let delegate = MijiaLANRustUpdateDelegate::alloc(mtm).set_ivars(ReminderState::default());
        let delegate: Retained<MijiaLANRustUpdateDelegate> =
            unsafe { msg_send![super(delegate), init] };
        // Messages match Sparkle's pinned public Objective-C headers. Both objects outlive all panels.
        let (controller, updater) = unsafe {
            let allocated: Allocated<AnyObject> = msg_send![class, alloc];
            let controller: Retained<AnyObject> = msg_send![allocated,
                initWithStartingUpdater: false,
                updaterDelegate: Option::<&AnyObject>::None,
                userDriverDelegate: &*delegate];
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
            delegate,
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
    pub fn automatically_downloads(&self) -> bool {
        unsafe { msg_send![&*self.updater, automaticallyDownloadsUpdates] }
    }
    pub fn set_automatically_downloads(&self, enabled: bool) {
        unsafe {
            let _: () = msg_send![&*self.updater, setAutomaticallyDownloadsUpdates: enabled];
        }
    }
    pub fn available(&self) -> Option<super::UpdateNotice> {
        self.delegate
            .ivars()
            .version
            .borrow()
            .clone()
            .map(|version| super::UpdateNotice {
                version: Some(version),
            })
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
