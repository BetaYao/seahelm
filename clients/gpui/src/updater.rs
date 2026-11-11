//! Sparkle entry point for the macOS app bundle. The updater lives in a small
//! Swift dylib so the Rust client stays portable and only the macOS package
//! needs Sparkle.

#[cfg(target_os = "macos")]
pub fn start() {
    use std::ffi::{CStr, CString};
    use std::os::unix::ffi::OsStrExt;
    use std::sync::OnceLock;

    static HANDLE: OnceLock<usize> = OnceLock::new();

    #[link(name = "System")]
    unsafe extern "C" {
        fn dlopen(path: *const libc::c_char, mode: libc::c_int) -> *mut libc::c_void;
        fn dlsym(handle: *mut libc::c_void, symbol: *const libc::c_char) -> *mut libc::c_void;
    }

    let Some(executable) = std::env::current_exe().ok() else { return };
    let Some(contents) = executable.parent().and_then(|macos| macos.parent()) else { return };
    let library = contents.join("Frameworks/libSeahelmGPUIUpdater.dylib");
    if !library.is_file() {
        // `cargo run` and the standalone --session terminal are not app bundles.
        return;
    }

    let preferences = crate::user_config::read();
    let update = preferences.get("auto_update");
    let enabled = update
        .and_then(|v| v.get("enabled"))
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(true);
    let interval_hours = update
        .and_then(|v| v.get("check_interval_hours"))
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(1)
        .clamp(1, i32::MAX as i64 / 3600) as i32;

    let Ok(path) = CString::new(library.as_os_str().as_bytes()) else { return };
    let symbol = CStr::from_bytes_with_nul(b"seahelm_gpui_start_updater\0").unwrap();

    // SAFETY: the shipped dylib exports this exact C ABI symbol and remains
    // loaded for the lifetime of the process.
    unsafe {
        let handle = dlopen(path.as_ptr(), libc::RTLD_NOW);
        if handle.is_null() {
            eprintln!("seahelm-gpui: cannot load Sparkle updater dylib");
            return;
        }
        let start = dlsym(handle, symbol.as_ptr());
        if start.is_null() {
            eprintln!("seahelm-gpui: Sparkle updater entry point is missing");
            return;
        }
        type StartUpdater = unsafe extern "C" fn(libc::c_int, libc::c_int);
        let start: StartUpdater = std::mem::transmute(start);
        let _ = HANDLE.set(handle as usize);
        start(i32::from(enabled), interval_hours);
    }
}

#[cfg(not(target_os = "macos"))]
pub fn start() {}
