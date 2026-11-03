//! One pane's scan across polls: the per-pane flow of `StatusPublisher.swift`
//! (`pollAll`, `probedSession`, `resolveAgentType`, `shouldSkipUnchangedFrame`,
//! `idleObservation`, `roundStart`, `observedStatus`), without its timer,
//! queue and locks. The caller polls every pane every cycle (the Swift's
//! "preferred worktrees" stride was never switched on) and calls
//! [`PaneScanner::observe`] once per pane per poll.
//!
//! What changed from the Swift: the screen comes from seahelmd's snapshot,
//! so an unchanged frame is spotted by its `generation` instead of a hash of
//! the text, and there is no surface-less fallback to throttle.

use seahelm_core_types::{AgentStatus, AgentType, EventKind, QuestionFlags, Timestamp};

use crate::choices;
use crate::debounce::DebouncedStatusTracker;
use crate::detect::{self, Detection};
use crate::manifest::ManifestStore;
use crate::process::Probe;
use crate::Snapshot;

/// Even a stable screen is decoded again every this many polls, which bounds
/// how long a missed invalidation can leave the registry on a stale scan.
pub const UNCHANGED_FRAME_RECHECK_STRIDE: u64 = 15;

/// A probe's answer is reused for this many polls: walking the process tree
/// costs more than reading a screen.
pub const PROBE_REFRESH_STRIDE: u64 = 5;

/// What one poll knows about one pane.
#[derive(Clone, Copy, Debug)]
pub struct ScanInput<'a> {
    pub snapshot: &'a Snapshot,
    /// The registry's hook status for the pane.
    pub hook_status: AgentStatus,
    /// When a prompt last started a turn (registry `turn_started`).
    pub hook_turn_started: Option<Timestamp>,
    /// This cycle's process probe of the session, if one was taken; see
    /// [`PaneScanner::needs_probe`]. `Some(&Probe::miss())` when the table
    /// could not be read. `None` reuses a still-fresh cached answer and
    /// otherwise means the session has no process to look at.
    pub probe: Option<&'a Probe>,
    /// The agent the registry has on file for the pane.
    pub current_agent: AgentType,
    pub now: Timestamp,
}

/// What a poll produced. On a skipped frame `event` and `question` are None,
/// `agent_type` is the input's `current_agent` and `command_line` None: the
/// caller has nothing to apply.
#[derive(Clone, Debug, PartialEq)]
pub struct ScanOutput {
    /// `ScreenObserved`, for every frame that was looked at.
    pub event: Option<EventKind>,
    /// What the pane is running (the registry's `updateDetection`).
    pub agent_type: AgentType,
    /// The foreground job, for the title. Carried in `event` as well: the
    /// registry wants it through ingest so its change notifies observers.
    pub command_line: Option<String>,
    /// An approval dialog on screen, as a question card. Ingest it after
    /// `event`.
    pub question: Option<EventKind>,
}

/// Whether the process probe saw the session with no agent in it, and
/// whether that was this poll or an earlier one still inside the stride.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoAgentSighting {
    None,
    /// This poll's probe: strong enough to take an agent identity away.
    Fresh,
    /// Remembered from a recent probe: enough to distrust the screen, not to
    /// overrule a hook that has since said an agent started.
    Cached,
}

/// What identifies an unchanged frame. The Swift hashed the text, the OSC
/// title and the progress; the generation moves on every write, which covers
/// all three, and the size is in because a resize redraws without a write
/// of its own.
#[derive(Clone, Debug, PartialEq, Eq)]
struct FrameKey {
    generation: u64,
    cols: u16,
    rows: u16,
    title: String,
    progress: String,
}

/// The cached probe answer.
#[derive(Clone, Debug, Default)]
struct ProbeCache {
    agent: Option<AgentType>,
    command_line: Option<String>,
    no_agent: bool,
    at_cycle: Option<u64>,
}

/// One pane's scan state across polls.
#[derive(Clone, Debug)]
pub struct PaneScanner {
    tracker: DebouncedStatusTracker,
    last_frame: Option<FrameKey>,
    /// The scan status last handed to the registry. The Swift read the
    /// registry's copy back (`scanStatus`); only this scanner writes it, so
    /// keeping it here is the same value without the round trip.
    published: Option<AgentStatus>,
    running_since: Option<Timestamp>,
    cycle: u64,
    /// Staggers this pane's forced recheck against the others'.
    offset: i64,
    probe: ProbeCache,
}

impl Default for PaneScanner {
    fn default() -> Self {
        Self::new()
    }
}

impl PaneScanner {
    pub fn new() -> Self {
        PaneScanner {
            tracker: DebouncedStatusTracker::new(),
            last_frame: None,
            published: None,
            running_since: None,
            cycle: 0,
            offset: 0,
            probe: ProbeCache::default(),
        }
    }

    /// A scanner whose forced rechecks are staggered by the pane key, so a
    /// fleet's panes do not all re-decode on the same poll.
    pub fn for_pane(pane: &str) -> Self {
        // Truncated to a signed offset as the Swift's `Int(truncatingIfNeeded:)` did.
        PaneScanner { offset: djb2(pane) as i64, ..Self::new() }
    }

    /// A hook arrived: the registry's arbitration may have moved while the
    /// frame did not, so look at the next frame even if it is unchanged.
    pub fn invalidate(&mut self) {
        self.last_frame = None;
    }

    /// The committed (debounced) scan status.
    pub fn status(&self) -> AgentStatus {
        self.tracker.current_status()
    }

    /// Whether the next [`observe`](PaneScanner::observe) would use a fresh
    /// probe. When false the caller can skip capturing the process table.
    pub fn needs_probe(&self) -> bool {
        !self.probe_is_fresh(self.cycle + 1)
    }

    fn probe_is_fresh(&self, cycle: u64) -> bool {
        let c = &self.probe;
        let recent = c.at_cycle.is_some_and(|last| cycle - last < PROBE_REFRESH_STRIDE);
        recent && (c.agent.is_some() || c.command_line.is_some() || c.no_agent)
    }

    /// One poll of this pane.
    pub fn observe(&mut self, input: &ScanInput, store: &ManifestStore) -> ScanOutput {
        self.cycle += 1;
        let snap = input.snapshot;
        let skipped = ScanOutput { event: None, agent_type: input.current_agent, command_line: None, question: None };
        // A held session that has not started, or a daemon with nothing to
        // show: skip without recording the frame, so the first real one is
        // looked at.
        if snap.started == Some(false) || snap.viewport.is_empty() {
            return skipped;
        }

        let osc_progress = snap.osc_progress();
        let key = FrameKey { generation: snap.generation, cols: snap.cols, rows: snap.rows, title: snap.title.clone(), progress: osc_progress.clone() };
        let force = on_stride(self.cycle, self.offset, UNCHANGED_FRAME_RECHECK_STRIDE);
        if should_skip_unchanged_frame(
            self.last_frame.as_ref() == Some(&key),
            Some(self.tracker.current_status()),
            self.published,
            force,
            input.hook_status,
        ) {
            return skipped;
        }
        self.last_frame = Some(key);

        let content = &snap.viewport;
        let lower = content.to_lowercase();
        let (probed, command_line, no_agent) = self.probed(input.probe);
        let mut agent_type = resolve_agent_type(
            probed,
            no_agent,
            AgentType::detect_from_lowercased(&lower),
            input.current_agent,
            |t| store.can_identify(t),
        );
        // Shell jobs (brew, make, …) have no manifest: classify from argv.
        if let Some(cmd) = &command_line {
            if !agent_type.is_ai_agent() {
                let from_cmd = AgentType::detect_from_command(cmd);
                if from_cmd != AgentType::Unknown {
                    agent_type = from_cmd;
                }
            }
        }
        let manifest = store.get(agent_type.manifest_id());
        let activity = detect::extract_activity_events(content, input.now);
        let detection = detect::detect(snap.process_status(), content, manifest, &snap.title, &osc_progress);

        let (visible_idle, defaulted) = idle_observation(&detection, input.hook_status);
        let old = self.tracker.current_status();
        let changed = self.tracker.update(detection.state, visible_idle, defaulted);
        let committed = self.tracker.current_status();
        let round_duration = round_start(self.running_since, input.hook_turn_started).map(|s| input.now - s).unwrap_or(0.0);
        if changed {
            if committed == AgentStatus::Running && old != AgentStatus::Running {
                self.running_since = Some(input.now);
            } else if committed != AgentStatus::Running && old == AgentStatus::Running {
                self.running_since = None;
            }
        }

        // Permission dialogs are drawn by the TUI, not sent through hooks.
        let options = choices::parse(content, choices::DEFAULT_BOTTOM_LINES);
        let has_approval = agent_type.is_ai_agent() && !options.is_empty();
        let status = observed_status(committed, has_approval);
        self.published = Some(status);

        let event = EventKind::ScreenObserved {
            status,
            message: String::new(),
            activity,
            command_line: command_line.clone(),
            agent_type,
            round_duration,
            // Tasks come from hooks (the provider), not the screen; empty
            // leaves the registry's list alone.
            tasks: Vec::new(),
            background_busy: detection.background_busy,
        };
        let question = (has_approval && !choices::is_agent_question_dialog(content, choices::DEFAULT_BOTTOM_LINES)).then(|| {
            EventKind::Question {
                prompt: format!("{} requires approval", agent_type.display_name()),
                options: options.into_iter().map(|o| o.label).collect(),
                followups: Vec::new(),
                flags: QuestionFlags::default(),
            }
        });
        ScanOutput { event: Some(event), agent_type, command_line, question }
    }

    /// The probe answer for this poll, through the cache (`probedSession`).
    fn probed(&mut self, fresh: Option<&Probe>) -> (AgentType, Option<String>, NoAgentSighting) {
        if self.probe_is_fresh(self.cycle) {
            let c = &self.probe;
            if let Some(agent) = c.agent {
                return (agent, c.command_line.clone(), NoAgentSighting::None);
            }
            let sighting = if c.no_agent { NoAgentSighting::Cached } else { NoAgentSighting::None };
            return (AgentType::Unknown, c.command_line.clone(), sighting);
        }
        let Some(p) = fresh else { return (AgentType::Unknown, None, NoAgentSighting::None) };
        let agent = p.agent.filter(|a| *a != AgentType::Unknown);
        let saw_no_agent = p.saw_session && agent.is_none();
        // A miss keeps the known identity: it says nothing about the agent.
        // Seeing the session with no agent in it does: the agent exited.
        if agent.is_some() {
            self.probe.agent = agent;
            self.probe.no_agent = false;
        } else if saw_no_agent {
            self.probe.agent = None;
            self.probe.no_agent = true;
        }
        // The command line tracks the current foreground job, so a probe
        // without one clears it, or a finished `brew update` would title the
        // pane for good.
        self.probe.command_line = p.foreground_command_line.clone();
        self.probe.at_cycle = Some(self.cycle);
        let sighting = if saw_no_agent { NoAgentSighting::Fresh } else { NoAgentSighting::None };
        (self.probe.agent.unwrap_or(AgentType::Unknown), self.probe.command_line.clone(), sighting)
    }
}

/// djb2, as the Swift's `stableHash`, for the recheck stagger.
fn djb2(s: &str) -> u64 {
    s.bytes().fold(5381u64, |h, b| (h << 5).wrapping_add(h).wrapping_add(b as u64))
}

/// Whether `cycle` is this pane's turn in a `stride`-cycle window, staggered
/// by `offset` (the Swift's `shouldBackendCapture`, which also timed the
/// forced recheck). Offsets come from a hash and may be negative; the
/// window is still hit exactly once per `stride` cycles.
pub fn on_stride(cycle: u64, offset: i64, stride: u64) -> bool {
    let s = stride.max(1) as i128;
    (cycle as i128 + offset as i128).rem_euclid(s) == 0
}

/// The pane's agent type for this poll.
///
/// An identity is not permanent: when the probe saw the session and found no
/// agent, a pane whose agent exited must stop reading as one, or a remote
/// client cannot tell whether a message would reach an agent. The screen
/// cannot settle it, because scrollback names the agent long after it left.
/// Only agents the probe can recognise are taken away; for the rest, not
/// finding one proves nothing.
pub fn resolve_agent_type(
    probed: AgentType,
    no_agent: NoAgentSighting,
    screen: AgentType,
    existing: AgentType,
    probe_can_see: impl Fn(AgentType) -> bool,
) -> AgentType {
    if probed != AgentType::Unknown {
        return probed;
    }
    let screen_counts = no_agent == NoAgentSighting::None || !probe_can_see(screen);
    let detected = if screen_counts { screen } else { AgentType::Unknown };
    let ty = if detected == AgentType::Unknown { existing } else { detected };
    if no_agent == NoAgentSighting::Fresh && ty.is_ai_agent() && probe_can_see(ty) {
        return AgentType::ShellCommand;
    }
    ty
}

/// How a frame's idle is weighed: `(visible_idle, defaulted)`. The long hold
/// on a defaulted idle is for agents only the screen can judge. A pane whose
/// hooks last reported Stop has said it finished, so its idle commits at
/// once; held, it outlasted the hook's own idle window and bounced the pane
/// back to running for ~10 s after every turn.
pub fn idle_observation(detection: &Detection, hook_status: AgentStatus) -> (bool, bool) {
    if hook_status == AgentStatus::Idle {
        (true, false)
    } else {
        (detection.visible_idle, detection.is_defaulted)
    }
}

/// Where a running pane's round counts from: when the scan saw it start, or
/// when a prompt started the turn if that is later. A prompt sent seconds
/// after the last turn is a new round even if no scan saw the pane idle in
/// between.
pub fn round_start(scan_running_since: Option<Timestamp>, turn_started: Option<Timestamp>) -> Option<Timestamp> {
    let since = scan_running_since?;
    Some(match turn_started {
        Some(t) => since.max(t),
        None => since,
    })
}

/// A frame showing an approval dialog is waiting whatever the rules made of
/// it. Reporting the heuristic status first made the pane flip to waiting
/// and back on every poll for as long as the dialog stayed up.
pub fn observed_status(committed: AgentStatus, shows_approval: bool) -> AgentStatus {
    if shows_approval {
        AgentStatus::Waiting
    } else {
        committed
    }
}

/// Whether an unchanged frame can be skipped.
pub fn should_skip_unchanged_frame(
    unchanged: bool,
    committed_scan_status: Option<AgentStatus>,
    published_scan_status: Option<AgentStatus>,
    force_recheck: bool,
    hook_status: AgentStatus,
) -> bool {
    if !unchanged || force_recheck {
        return false;
    }
    // The hooks say the turn ended but the scan still holds it running: look
    // again, or an unchanged screen keeps the hold alive until the next
    // forced recheck.
    if hook_status == AgentStatus::Idle && committed_scan_status == Some(AgentStatus::Running) {
        return false;
    }
    committed_scan_status.is_some() && committed_scan_status == published_scan_status
}
