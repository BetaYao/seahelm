//! Agent lifecycle hooks for seahelm-core: the payloads agents send, what
//! they mean, and the shims that send them.
//!
//! Ported from the Swift app (`Sources/Status/WebhookEvent.swift`,
//! `HookDecoder.swift`, `WebhookStatusProvider.swift`,
//! `AgentWorkLocation.swift`, `Sources/Core/StopHookResponder.swift`,
//! `AgentSessionRef.swift`, the session title lookups and the hook
//! installers). The Swift tests are the spec; each one lives on as a Rust
//! test of the same name in snake_case next to the code it pins.
//!
//! Everything here is pure: no threads, timers, sockets or globals. Time
//! comes in as a `Timestamp`, and the filesystem is touched only where the
//! Swift reads files (title lookups, installers, the worktree-root probe the
//! provider is handed), behind a path argument. The one piece of I/O, the
//! `seahelm-hook` binary, lives in `src/bin/` and gets its wire format from
//! [`wire`].

pub mod activity;
pub mod cursor_store;
pub mod decode;
pub mod event;
pub mod install;
pub mod location;
pub mod prompt;
pub mod provider;
pub mod session_ref;
pub mod sink;
pub mod suggest;
pub mod titles;
pub mod wire;

mod paths;

pub use event::{WebhookEvent, WebhookEventType};
pub use provider::Provider;
pub use session_ref::AgentSessionRef;

/// The object a hook payload's `data` is, and what every reader indexes.
pub type Map = serde_json::Map<String, serde_json::Value>;

/// The home directory: `HOME`, else `USERPROFILE` (Windows), else empty.
/// Only for callers that were given no home of their own.
pub fn home_dir() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .or_else(|| std::env::var_os("USERPROFILE").filter(|h| !h.is_empty()))
        .map(std::path::PathBuf::from)
        .unwrap_or_default()
}
