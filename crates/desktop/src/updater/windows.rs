use anyhow::{Context, ensure};
use libloading::os::windows::Library;
use std::{
    ffi::{CString, c_char},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
};
use windows::{
    Win32::{
        Foundation::ERROR_SUCCESS,
        System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_SZ, RegGetValueW},
    },
    core::w,
};

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);
static UPDATE_AVAILABLE: AtomicBool = AtomicBool::new(false);
pub fn take_shutdown_request() -> bool {
    SHUTDOWN_REQUESTED.swap(false, Ordering::AcqRel)
}
unsafe extern "C" fn request_shutdown() {
    UPDATE_AVAILABLE.store(false, Ordering::Release);
    SHUTDOWN_REQUESTED.store(true, Ordering::Release);
}
unsafe extern "C" fn found_update() {
    UPDATE_AVAILABLE.store(true, Ordering::Release);
}
unsafe extern "C" fn clear_update() {
    UPDATE_AVAILABLE.store(false, Ordering::Release);
}
unsafe extern "C" fn can_shutdown() -> i32 {
    1
}

#[derive(serde::Deserialize)]
struct PackageInfo {
    product: String,
    platform: String,
    version: String,
    build: u32,
}

pub struct Updater {
    _library: Library,
    cleanup: unsafe extern "C" fn(),
    check: unsafe extern "C" fn(),
    automatic: unsafe extern "C" fn() -> i32,
    set_automatic: unsafe extern "C" fn(i32),
}

fn installed_in(folder: &Path) -> bool {
    let mut buffer = [0u16; 32768];
    let mut size = (buffer.len() * 2) as u32;
    // The installer writes this per-user value; portable copies must never silently migrate elsewhere.
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\iPocket\\MijiaLAN Rust\\Installer"),
            w!("InstallPath"),
            RRF_RT_REG_SZ,
            None,
            Some(buffer.as_mut_ptr().cast()),
            Some(&mut size),
        )
    };
    if status != ERROR_SUCCESS {
        return false;
    }
    let end = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
    let installed = std::path::PathBuf::from(String::from_utf16_lossy(&buffer[..end]));
    match (installed.canonicalize(), folder.canonicalize()) {
        (Ok(a), Ok(b)) => a
            .to_string_lossy()
            .eq_ignore_ascii_case(&b.to_string_lossy()),
        _ => false,
    }
}
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain([0]).collect()
}

impl Updater {
    pub fn smoke() -> anyhow::Result<()> {
        let exe = std::env::current_exe()?;
        let folder = exe.parent().context("Missing application directory")?;
        let library =
            unsafe { Library::load_with_flags(folder.join("WinSparkle.dll"), 0x100 | 0x1000) }?;
        for name in [
            c"win_sparkle_init",
            c"win_sparkle_cleanup",
            c"win_sparkle_check_update_with_ui",
            c"win_sparkle_set_appcast_url",
            c"win_sparkle_set_eddsa_public_key",
            c"win_sparkle_set_app_details",
            c"win_sparkle_set_app_build_version",
            c"win_sparkle_set_registry_path",
            c"win_sparkle_set_update_check_interval",
            c"win_sparkle_set_shutdown_request_callback",
            c"win_sparkle_set_can_shutdown_callback",
            c"win_sparkle_get_automatic_check_for_updates",
            c"win_sparkle_set_automatic_check_for_updates",
            c"win_sparkle_set_did_find_update_callback",
            c"win_sparkle_set_did_not_find_update_callback",
            c"win_sparkle_set_error_callback",
            c"win_sparkle_set_update_dismissed_callback",
        ] {
            unsafe {
                library.get::<unsafe extern "C" fn()>(name.to_bytes_with_nul())?;
            }
        }
        let set_key = unsafe {
            library.get::<unsafe extern "C" fn(*const c_char) -> i32>(
                b"win_sparkle_set_eddsa_public_key\0",
            )?
        };
        ensure!(
            unsafe { set_key(CString::new(super::PUBLIC_KEY)?.as_ptr()) } != 0,
            "Invalid update public key"
        );
        Ok(())
    }
    pub fn start() -> anyhow::Result<Self> {
        let exe = std::env::current_exe()?;
        let folder = exe.parent().context("Missing application directory")?;
        ensure!(
            installed_in(folder),
            "Install the per-user MSI to enable updates; this is a portable/development copy"
        );
        let package: PackageInfo =
            serde_json::from_slice(&std::fs::read(folder.join("mijialan-update.json"))?)?;
        ensure!(
            package.product == "mijialan-rs"
                && package.platform == "windows-x86_64"
                && package.version == env!("CARGO_PKG_VERSION")
                && (1..=65535).contains(&package.build),
            "Invalid release metadata"
        );
        // Absolute, adjacent DLL only; never search the process CWD or PATH.
        let library =
            unsafe { Library::load_with_flags(folder.join("WinSparkle.dll"), 0x100 | 0x1000) }?;
        unsafe {
            let set_url = library
                .get::<unsafe extern "C" fn(*const c_char)>(b"win_sparkle_set_appcast_url\0")?;
            let set_key = library.get::<unsafe extern "C" fn(*const c_char) -> i32>(
                b"win_sparkle_set_eddsa_public_key\0",
            )?;
            let set_details = library
                .get::<unsafe extern "C" fn(*const u16, *const u16, *const u16)>(
                    b"win_sparkle_set_app_details\0",
                )?;
            let set_build = library
                .get::<unsafe extern "C" fn(*const u16)>(b"win_sparkle_set_app_build_version\0")?;
            let set_registry = library
                .get::<unsafe extern "C" fn(*const c_char)>(b"win_sparkle_set_registry_path\0")?;
            let set_interval = library
                .get::<unsafe extern "C" fn(i32)>(b"win_sparkle_set_update_check_interval\0")?;
            let set_shutdown = library.get::<unsafe extern "C" fn(unsafe extern "C" fn())>(
                b"win_sparkle_set_shutdown_request_callback\0",
            )?;
            let set_can_shutdown = library
                .get::<unsafe extern "C" fn(unsafe extern "C" fn() -> i32)>(
                    b"win_sparkle_set_can_shutdown_callback\0",
                )?;
            let init = library.get::<unsafe extern "C" fn()>(b"win_sparkle_init\0")?;
            // Resolve every symbol before initializing the library; cleanup always runs before unloading.
            let cleanup = *library.get(b"win_sparkle_cleanup\0")?;
            let check = *library.get(b"win_sparkle_check_update_with_ui\0")?;
            let automatic = *library.get(b"win_sparkle_get_automatic_check_for_updates\0")?;
            let set_automatic = *library.get(b"win_sparkle_set_automatic_check_for_updates\0")?;
            // WinSparkle may invoke these off the UI thread. Only atomics are touched here;
            // the application refreshes its indicators on the main thread.
            for (name, callback) in [
                (
                    c"win_sparkle_set_did_find_update_callback",
                    found_update as unsafe extern "C" fn(),
                ),
                (
                    c"win_sparkle_set_did_not_find_update_callback",
                    clear_update as unsafe extern "C" fn(),
                ),
                (
                    c"win_sparkle_set_error_callback",
                    clear_update as unsafe extern "C" fn(),
                ),
                (
                    c"win_sparkle_set_update_dismissed_callback",
                    clear_update as unsafe extern "C" fn(),
                ),
            ] {
                library.get::<unsafe extern "C" fn(unsafe extern "C" fn())>(
                    name.to_bytes_with_nul(),
                )?(callback);
            }
            set_url(CString::new(super::feed_url("windows-x86_64"))?.as_ptr());
            ensure!(
                set_key(CString::new(super::PUBLIC_KEY)?.as_ptr()) != 0,
                "Invalid Ed25519 key"
            );
            set_details(
                wide("iPocket").as_ptr(),
                wide("MijiaLAN Rust").as_ptr(),
                wide(&package.version).as_ptr(),
            );
            set_build(wide(&package.build.to_string()).as_ptr());
            set_registry(c"Software\\iPocket\\MijiaLAN Rust\\Updates".as_ptr());
            set_interval(86400);
            set_shutdown(request_shutdown);
            set_can_shutdown(can_shutdown);
            UPDATE_AVAILABLE.store(false, Ordering::Release);
            init();
            Ok(Self {
                _library: library,
                cleanup,
                check,
                automatic,
                set_automatic,
            })
        }
    }
    pub fn can_check(&self) -> bool {
        true
    }
    pub fn automatically_checks(&self) -> bool {
        unsafe { (self.automatic)() != 0 }
    }
    pub fn set_automatically_checks(&self, enabled: bool) {
        unsafe {
            (self.set_automatic)(i32::from(enabled));
        }
    }
    pub fn check(&self) {
        unsafe {
            (self.check)();
        }
    }
    pub fn available(&self) -> Option<super::UpdateNotice> {
        // This public WinSparkle callback does not provide the display version.
        UPDATE_AVAILABLE
            .load(Ordering::Acquire)
            .then_some(super::UpdateNotice { version: None })
    }
}
impl Drop for Updater {
    fn drop(&mut self) {
        unsafe {
            (self.cleanup)();
        }
    }
}
