//! Read and update the registered login item for this application bundle.
use objc2::{
    msg_send,
    rc::Retained,
    runtime::{AnyClass, AnyObject},
};
use objc2_foundation::{NSBundle, NSError, NSString};
use std::{ffi::c_void, ptr};

#[link(name = "ServiceManagement", kind = "framework")]
unsafe extern "C" {
    static kSMDomainUserLaunchd: *const c_void;
    fn SMJobCopyDictionary(domain: *const c_void, label: *const c_void) -> *const c_void;
    fn SMLoginItemSetEnabled(identifier: *const c_void, enabled: u8) -> u8;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(object: *const c_void);
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Disabled,
    Enabled,
    PendingApproval,
}

fn is_main_bundle() -> bool {
    NSBundle::mainBundle()
        .bundleIdentifier()
        .is_some_and(|id| *id == *NSString::from_str("xyz.ipocket.MijiaLAN.Rust"))
}

fn helper_identifier() -> Option<Retained<NSString>> {
    let path = NSBundle::mainBundle().bundlePath();
    let helper = NSString::from_str(&format!(
        "{path}/Contents/Library/LoginItems/MijiaLANRustLoginItem.app"
    ));
    NSBundle::bundleWithPath(&helper)?.bundleIdentifier()
}

fn services(class: &AnyClass) -> [Option<Retained<AnyObject>>; 2] {
    // These selectors are provided by SMAppService on macOS 13 and later.
    let main = unsafe { msg_send![class, mainAppService] };
    let helper = helper_identifier()
        .and_then(|id| unsafe { msg_send![class, loginItemServiceWithIdentifier: &*id] });
    [main, helper]
}

fn read(service: &AnyObject) -> Option<Status> {
    // SMAppServiceStatus is an NSInteger. NotFound and future values are unavailable.
    match unsafe { msg_send![service, status] } {
        0_isize => Some(Status::Disabled),
        1_isize => Some(Status::Enabled),
        2_isize => Some(Status::PendingApproval),
        _ => None,
    }
}

pub fn status() -> Option<Status> {
    if !is_main_bundle() {
        return None;
    }
    if let Some(class) = AnyClass::get(c"SMAppService") {
        let [main, helper] = services(class).map(|service| service.as_deref().and_then(read));
        let statuses = [main, helper];
        if statuses.contains(&Some(Status::Enabled)) {
            return Some(Status::Enabled);
        }
        if statuses.contains(&Some(Status::PendingApproval)) {
            return Some(Status::PendingApproval);
        }
        return main;
    }
    let helper = helper_identifier()?;
    // NSString is toll-free bridged to CFString. Copy returns a retained CFDictionary.
    let job = unsafe { SMJobCopyDictionary(kSMDomainUserLaunchd, ptr::from_ref(&*helper).cast()) };
    if job.is_null() {
        Some(Status::Disabled)
    } else {
        unsafe { CFRelease(job) };
        Some(Status::Enabled)
    }
}

pub fn set(enabled: bool) -> anyhow::Result<()> {
    let unavailable = || anyhow::anyhow!("Login items unavailable");
    let status = status().ok_or_else(unavailable)?;
    if enabled == (status != Status::Disabled) {
        return Ok(());
    }
    let Some(class) = AnyClass::get(c"SMAppService") else {
        let helper = helper_identifier().ok_or_else(unavailable)?;
        // The helper identifier belongs to the installed bundle on this macOS version.
        let success =
            unsafe { SMLoginItemSetEnabled(ptr::from_ref(&*helper).cast(), u8::from(enabled)) };
        anyhow::ensure!(success != 0, "macOS could not update the login item");
        return Ok(());
    };
    let [main, helper] = services(class);
    if enabled {
        return set_service(main.as_deref().ok_or_else(unavailable)?, true);
    }
    for service in [helper, main].into_iter().flatten() {
        if matches!(
            read(&service),
            Some(Status::Enabled | Status::PendingApproval)
        ) {
            set_service(&service, false)?;
        }
    }
    Ok(())
}

fn set_service(service: &AnyObject, enabled: bool) -> anyhow::Result<()> {
    let result: Result<(), Retained<NSError>> = unsafe {
        if enabled {
            msg_send![service, registerAndReturnError: _]
        } else {
            msg_send![service, unregisterAndReturnError: _]
        }
    };
    result.map_err(|error| anyhow::anyhow!("{}", error.localizedDescription()))
}

pub fn open_settings() {
    if let Some(class) = AnyClass::get(c"SMAppService") {
        let _: () = unsafe { msg_send![class, openSystemSettingsLoginItems] };
    }
}
