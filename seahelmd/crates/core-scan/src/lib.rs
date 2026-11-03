//! Screen-scan status detection: what a pane's screen says its agent is
//! doing.
//!
//! Ported from the Swift app's scan path (`Sources/Status/StatusDetector.swift`,
//! `AgentManifest.swift`, `ManifestEngine.swift`, `ManifestStore.swift`,
//! `ProcessProbe.swift`, `ChoiceOptionParser.swift` and the per-pane flow of
//! `StatusPublisher.swift`). The Swift read the screen out of a Ghostty
//! surface under a lock; here it comes from seahelmd's `snapshot` (see
//! [`Snapshot`]), which works the same on every platform and for panes nobody
//! is looking at.
//!
//! Everything here is pure: no threads, timers or global state. Time comes in
//! as an argument, the only filesystem read is the user manifest directory,
//! and the only system read is the process table ([`process::ProcessTable`]).
//!
//! The flow for one pane per poll is [`pane::PaneScanner::observe`]:
//! snapshot → agent identity (process probe, then screen) → manifest rules
//! ([`detect`]) → debounce ([`debounce`]) → approval dialogs ([`choices`]) →
//! a `ScreenObserved` event for the registry.

use serde::Deserialize;

pub mod choices;
pub mod debounce;
pub mod detect;
pub mod explain;
pub mod manifest;
pub mod pane;
pub mod process;

pub use detect::{Detection, DetectionInput, ProcessStatus};
pub use manifest::{CompiledManifest, ManifestStore};

/// seahelmd's `snapshot` JSON (`Session::snapshot`, seahelmd/README.md): what
/// a status reader polls.
///
/// Every field defaults when missing, so an older or newer daemon still
/// parses: a reader that cannot see a field must behave as if the daemon said
/// nothing about it, not fail the whole poll.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Snapshot {
    /// `Some(false)` while a held session (`seahelmd new --hold`) has not
    /// started its program yet: there is nothing on screen worth judging.
    pub started: Option<bool>,
    /// Moves on every write the daemon's grid parses. An unchanged
    /// generation is an unchanged screen, which is what lets the scanner skip
    /// a frame without reading it (the Swift hashed the text instead).
    pub generation: u64,
    pub cols: u16,
    pub rows: u16,
    pub alt_screen: bool,
    /// OSC 0/2. Agents animate a spinner here while the viewport is static,
    /// and the manifests' `osc_title` rules read it as running.
    pub title: String,
    pub pwd: String,
    /// OSC 9;4.
    pub progress: Option<Progress>,
    /// Bumps whenever the live OSC 7501 root record changes, so a reader sees
    /// every change of it even between polls.
    pub program_seq: u64,
    pub program: Option<seahelm_core_types::ProgramStatus>,
    /// The visible screen as plain text, rows joined by `\n`.
    pub viewport: String,
    /// The program's exit status once it has one. Not reported by today's
    /// daemon (the field is in the design, `docs/status-core-port.md`); when it
    /// arrives it is the process-lifecycle tier of the detector, which in the
    /// Swift came from the Ghostty surface and so only ever saw the
    /// `seahelmd attach` client, never the agent.
    pub exited: Option<i32>,
}

/// An OSC 9;4 (ConEmu-style) progress report.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Progress {
    /// 0 remove, 1 set, 2 error, 3 indeterminate, 4 pause.
    pub state: u8,
    pub percent: Option<u8>,
}

impl Snapshot {
    /// The OSC 9;4 report as the manifests' `osc_progress` region reads it:
    /// `"<state>;<percent>"`, percent empty when none was reported, or `""`
    /// when there is no report at all. This is the wire string the Swift app
    /// built in `GhosttyBridge`, so manifest rules written against it (e.g.
    /// `^4;0`) keep matching.
    pub fn osc_progress(&self) -> String {
        match self.progress {
            Some(p) => match p.percent {
                Some(v) => format!("{};{}", p.state, v),
                None => format!("{};", p.state),
            },
            None => String::new(),
        }
    }

    /// The process-lifecycle signal: an exit code ends the detection ladder
    /// before any rule is read.
    pub fn process_status(&self) -> ProcessStatus {
        match self.exited {
            Some(0) => ProcessStatus::Exited,
            Some(_) => ProcessStatus::Error,
            None => ProcessStatus::Running,
        }
    }

    /// Parse the daemon's JSON answer.
    pub fn parse(json: &str) -> Result<Snapshot, serde_json::Error> {
        serde_json::from_str(json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_daemon_snapshot() {
        let json = r#"{"generation":7,"cols":80,"rows":24,"alt_screen":false,"title":"⠋ claude",
            "pwd":"/x","progress":{"state":1,"percent":40},"program_seq":2,
            "program":{"state":"working","kind":null,"progress":null,"app":"claude-code","title":"","msg":""},
            "viewport":"a\nb"}"#;
        let s = Snapshot::parse(json).unwrap();
        assert_eq!(s.generation, 7);
        assert_eq!(s.osc_progress(), "1;40");
        assert_eq!(s.program.as_ref().unwrap().state, seahelm_core_types::ProgramState::Working);
        assert_eq!(s.process_status(), ProcessStatus::Running);
        assert_eq!(s.started, None);
    }

    #[test]
    fn progress_without_percent_keeps_the_separator() {
        let s = Snapshot { progress: Some(Progress { state: 3, percent: None }), ..Default::default() };
        assert_eq!(s.osc_progress(), "3;");
        assert_eq!(Snapshot::default().osc_progress(), "");
    }
}
