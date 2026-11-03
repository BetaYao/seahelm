//! The detector: one screen in, what the agent is doing out.
//!
//! Ported from `StatusDetector.swift` (`detectDetailed`, the activity
//! regexes). The ladder is process lifecycle > manifest rules > unknown. The
//! Swift had an OSC 133 shell-phase tier between the two, but nothing ever fed
//! it (`shellInfo: nil` at every call site), so it is left out until the
//! daemon reports semantic prompts. The legacy `AgentDef` rules are gone too:
//! production only ever used them for a last-message string nobody read.

use std::sync::OnceLock;

use regex::Regex;
use seahelm_core_types::{ActivityEvent, AgentStatus, Timestamp};

use crate::manifest::CompiledManifest;

/// The program's lifecycle, the strongest signal there is.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ProcessStatus {
    /// Alive.
    Running,
    /// Exited with 0.
    Exited,
    /// Exited with anything else.
    Error,
    /// Not started, or nobody can say.
    #[default]
    Unknown,
}

/// What a frame says, with the flags the debounce layer weighs it by and the
/// rule that decided it (for `pane.explain`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Detection {
    pub state: AgentStatus,
    /// The frame proves the agent finished: commit idle at once.
    pub visible_idle: bool,
    pub visible_blocker: bool,
    pub visible_working: bool,
    pub skip_state_update: bool,
    pub matched_rule_id: Option<String>,
    /// No rule matched: `state` is the manifest's `default_status` filling the
    /// gap, not something seen on screen. Weaker than a match (see
    /// [`crate::debounce::DebouncedStatusTracker::update`]).
    pub is_defaulted: bool,
    /// The session has background work of its own (a shell it launched, a
    /// monitor it watches). Deliberately not a status: the agent can be parked
    /// at an empty prompt while this is true, and folding it into the status
    /// lost the running → idle edge that notifications ride on.
    pub background_busy: bool,
}

/// What the rules are matched against.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DetectionInput {
    /// The visible screen, lowercased (substring matchers are lowercased at
    /// compile time, so the two meet in lowercase).
    pub screen: String,
    pub osc_title: String,
    /// `"<state>;<percent>"`, see [`crate::Snapshot::osc_progress`].
    pub osc_progress: String,
}

impl DetectionInput {
    /// A screen with no OSC signals; `screen` must already be lowercased.
    pub fn screen(screen: impl Into<String>) -> Self {
        DetectionInput { screen: screen.into(), ..Default::default() }
    }

    pub fn title(screen: impl Into<String>, osc_title: impl Into<String>) -> Self {
        DetectionInput { screen: screen.into(), osc_title: osc_title.into(), osc_progress: String::new() }
    }
}

/// Detect from one frame. `content` is the raw screen; it is lowercased here
/// before any rule sees it.
///
/// With no manifest, or an empty screen, the answer is `Unknown` ("no data"),
/// which the tracker treats as no change.
pub fn detect(
    process: ProcessStatus,
    content: &str,
    manifest: Option<&CompiledManifest>,
    osc_title: &str,
    osc_progress: &str,
) -> Detection {
    match process {
        ProcessStatus::Exited => return Detection { state: AgentStatus::Exited, visible_idle: true, ..Default::default() },
        ProcessStatus::Error => return Detection { state: AgentStatus::Error, visible_blocker: true, ..Default::default() },
        ProcessStatus::Running | ProcessStatus::Unknown => {}
    }
    let Some(manifest) = manifest else { return Detection::default() };
    if content.is_empty() {
        return Detection::default();
    }
    let input = DetectionInput { screen: content.to_lowercase(), osc_title: osc_title.into(), osc_progress: osc_progress.into() };
    let d = manifest.evaluate(&input);
    if d.state == AgentStatus::Unknown {
        // Nothing matched, so the manifest's default fills the gap. That is a
        // baseline, not an observation: no shipped manifest has an idle rule,
        // so a defaulted idle means only "no running / waiting / error rule
        // matched this frame". Claiming visible_idle here (as the Swift once
        // did) let one frame of a thinking agent, spinner momentarily off
        // screen, end its turn and fire a completion banner mid-turn.
        // background_busy survives: it was observed.
        return Detection {
            state: manifest.default_status(),
            is_defaulted: true,
            background_busy: d.background_busy,
            ..Default::default()
        };
    }
    d
}

fn circle_pattern() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    // ⏺ ToolName(args) or ✗ ToolName(args)
    R.get_or_init(|| Regex::new(r"^[[:space:]]*([⏺✗])\s+(\w+)\((.+?)\)").expect("activity regex"))
}

fn arrow_pattern() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    // ▸ ToolName   detail or ✗ ToolName   detail
    R.get_or_init(|| Regex::new(r"^[[:space:]]*([▸✗])\s+(\w+)\s{2,}(.+)$").expect("activity regex"))
}

/// Tool-call lines on screen (`⏺ Tool(detail)`, `▸ Tool   detail`, `✗` for a
/// failure), newest (bottom) first, at most 20, stamped `now`.
pub fn extract_activity_events(text: &str, now: Timestamp) -> Vec<ActivityEvent> {
    if text.is_empty() {
        return Vec::new();
    }
    let mut events: Vec<ActivityEvent> = text
        .split(['\n', '\r', '\u{0B}', '\u{0C}', '\u{85}', '\u{2028}', '\u{2029}'])
        .filter_map(|line| {
            let caps = circle_pattern().captures(line).or_else(|| arrow_pattern().captures(line))?;
            let marker = caps.get(1)?.as_str();
            Some(ActivityEvent {
                tool: caps.get(2)?.as_str().to_string(),
                detail: crate::manifest::trim_ws(caps.get(3)?.as_str()).to_string(),
                is_error: marker == "✗",
                timestamp: now,
            })
        })
        .collect();
    events.reverse();
    events.truncate(20);
    events
}
