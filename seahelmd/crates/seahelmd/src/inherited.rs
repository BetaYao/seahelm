//! What a client must not pass on to the sessions it starts.
//!
//! A client (the GPUI client, seahelm-core) is often launched from a shell
//! inside a seahelm pane: a dev rebuild, an agent restarting it. That shell's
//! session identity is in its environment, and every session the client
//! starts would inherit it — so an agent in a new pane reports its hooks
//! under the launching pane's id (`seahelm-hook` reads `SEAHELM_PANE_ID`
//! first), and a Claude Code that inherits another session's
//! `CLAUDE_CODE_CHILD_SESSION` stops saving its transcript. The Swift app
//! scrubs the same list (`Sources/App/main.swift`, which also says why
//! `NO_COLOR` is on it).

pub const LEAKED: &[&str] = &[
    "SEAHELMD_SESSION",
    "SEAHELM_ENV",
    "SEAHELM_SOCKET_PATH",
    "SEAHELM_PANE_ID",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "NO_COLOR",
];

/// Drop the launching pane's identity from this process's environment.
/// Call first thing in `main`, before any thread or child exists.
pub fn scrub() {
    for k in LEAKED {
        std::env::remove_var(k);
    }
}
