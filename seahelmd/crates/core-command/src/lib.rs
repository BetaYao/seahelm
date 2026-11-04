//! The command language (`docs/command-redesign.md`), spoken identically by
//! the island's command line, chat and mail: `#7` is a pane by its stable
//! handle, `@branch` / `@repo/branch` a worktree, `@repo` a repo.
//!
//! Ported from the app's `Sources/Core/Command/`. Per the core/gateway
//! boundary (docs/first-mate-core.md) the core parses and runs a line; which
//! pane a conversation is bound to, and a question waiting on `/yes`, are the
//! caller's state, passed in with each line and handed back changed.

pub mod exec;
pub mod fleet;
pub mod format;
pub mod handles;
pub mod parse;
pub mod spec;

pub use exec::{run, Binding, Button, Context, Host, Outcome, Reply};
pub use fleet::{FleetIndex, PaneRef, RepoRef, WorktreeRef};
pub use handles::Handles;
