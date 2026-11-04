//! Where the gateway keeps things, and the sockets it speaks on.

use std::path::PathBuf;

/// `~/.config/seahelm`, the directory every seahelm component shares.
pub fn config_dir() -> PathBuf {
    let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).unwrap_or_default();
    PathBuf::from(home).join(".config/seahelm")
}

/// `$SEAHELM_GATEWAY_DIR`, else `~/.config/seahelm/gateway`: the gateway's
/// own config, secrets and state. Nobody else reads it.
pub fn gateway_dir() -> PathBuf {
    if let Some(p) = std::env::var_os("SEAHELM_GATEWAY_DIR") {
        return PathBuf::from(p);
    }
    config_dir().join("gateway")
}

/// The current user, for pipe names: pipes are machine-wide.
#[cfg(windows)]
fn user() -> String {
    std::env::var("USERNAME").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "default".into())
}

/// `$SEAHELM_GATEWAY_SOCKET`, else `~/.config/seahelm/gateway.sock` (on
/// Windows the pipe `\\.\pipe\seahelm-gateway-<user>`).
pub fn gateway_socket() -> PathBuf {
    if let Some(p) = std::env::var_os("SEAHELM_GATEWAY_SOCKET") {
        return PathBuf::from(p);
    }
    #[cfg(windows)]
    return PathBuf::from(format!(r"\\.\pipe\seahelm-gateway-{}", user()));
    #[cfg(not(windows))]
    config_dir().join("gateway.sock")
}

/// seahelm-core's socket, as the core itself resolves it.
pub fn core_socket() -> PathBuf {
    if let Some(p) = std::env::var_os("SEAHELM_CORE_SOCKET") {
        return PathBuf::from(p);
    }
    #[cfg(windows)]
    return PathBuf::from(format!(r"\\.\pipe\seahelm-core-{}", user()));
    #[cfg(not(windows))]
    config_dir().join("core.sock")
}

/// The seahelm-web files: `config.web.web_root` when set, else `seahelm-web`
/// beside the binary's bundle (`Contents/Resources/seahelm-web` when the
/// binary is `Contents/Resources/bin/seahelm-gateway`), else beside the binary.
pub fn web_root(configured: Option<&str>) -> Option<PathBuf> {
    if let Some(c) = configured.map(str::trim).filter(|c| !c.is_empty()) {
        let expanded = if let Some(rest) = c.strip_prefix("~/") {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(rest)
        } else {
            PathBuf::from(c)
        };
        return expanded.is_dir().then_some(expanded);
    }
    let exe = std::env::current_exe().ok()?;
    let bin = exe.parent()?;
    [bin.parent().map(|r| r.join("seahelm-web")), Some(bin.join("seahelm-web"))].into_iter().flatten().find(|p| p.is_dir())
}
