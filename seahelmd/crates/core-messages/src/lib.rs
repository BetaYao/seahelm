//! Each pane's message timeline: what the user said, what the agent did
//! and said, the decisions it asked for, and its turns starting and ending.
//! What Island's First Mate conversation, seahelm-web's Timeline and any
//! other client draw — semantic events, not terminal text.
//!
//! Ported from the app (`MessageEvent`, `PaneMessageProjector`,
//! `MessageStreamHub` / `MessageStreamStore`, `AgentTranscriptTail`). The
//! timeline is a projection of the registry's outcomes, which the core
//! already makes, plus the prose an agent writes between tool calls, read
//! from its own transcript. Pure apart from the store's files.

pub mod event;
pub mod hub;
pub mod project;
pub mod transcript;

pub use event::{Kind, Message};
pub use hub::{Hub, Replay};
pub use project::{project, Coalesce};
pub use transcript::{CursorTail, Tail};
