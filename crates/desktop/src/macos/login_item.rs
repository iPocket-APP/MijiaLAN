//! Read and update the registered login item for this application bundle.
use objc2::{
    msg_send,
    rc::Retained,
    runtime::{AnyClass, AnyObject},
};
use objc2_foundation::{NSBundle, NSError};

#[link(name = "ServiceManagement", kind = "framework")]
unsafe extern "C" {}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Disabled,
    Enabled,
    PendingApproval,
}

fn service() -> Option<Retained<AnyObject>> {
    let id = NSBundle::mainBundle().bundleIdentifier()?;
    if id.to_string() != "xyz.ipocket.MijiaLAN.Rust" {
        return None;
    }
    let class = AnyClass::get(c"SMAppService")?;
    // The class is only available on macOS 13 and later.
    unsafe { msg_send![class, mainAppService] }
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
    let service = service()?;
    read(&service)
}

pub fn set(enabled: bool) -> anyhow::Result<()> {
    let service = service().ok_or_else(|| anyhow::anyhow!("Login items unavailable"))?;
    let status = read(&service).ok_or_else(|| anyhow::anyhow!("Login item status unavailable"))?;
    if enabled == (status != Status::Disabled) {
        return Ok(());
    }
    let result: Result<(), Retained<NSError>> = unsafe {
        if enabled {
            msg_send![&*service, registerAndReturnError: _]
        } else {
            msg_send![&*service, unregisterAndReturnError: _]
        }
    };
    result.map_err(|error| anyhow::anyhow!("{}", error.localizedDescription()))
}

pub fn open_settings() {
    if let Some(class) = AnyClass::get(c"SMAppService") {
        let _: () = unsafe { msg_send![class, openSystemSettingsLoginItems] };
    }
}
