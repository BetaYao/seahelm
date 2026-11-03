# seahelm-core crates: the contract between them

Design and rationale: `docs/status-core-port.md`. This file says which crate
owns what, and the public API each one gives `seahelm-core`, the binary
that wires them together. The crates live in the `seahelmd/` workspace.

```
seahelm-core-types     shared vocabulary (done): AgentStatus, AgentType, Authority,
                       ActivityEvent, TaskItem, QuestionSpec/Flags, ProgramStatus,
                       EventSource, EventKind, NormalizedEvent, Timestamp
seahelm-core-hooks     hook payloads → events; per-session hook state; agent location;
                       session refs and title lookups; hook installers; `seahelm-hook` bin
seahelm-core-scan      manifests, detector, debounce, choice dialogs, activity lines,
                       process identification, the per-pane scanner, explain
seahelm-core-registry  panes, ingest + arbitration, timers, unseen completion, rollups,
                       notification decision, event hub
seahelm-core (bin)     JSON-RPC server, seahelmd polling, wiring, persistence
```

## Rules for every crate

- **Port behaviour, not structure.** The Swift tests named in each section
  are the spec. Port each one to a Rust test with the same name in
  snake_case. Keep dead code dead; `docs/status-core-port.md` lists what is
  dead.
- **Pure where the Swift is pure.** No threads, timers, sockets or global
  singletons inside these crates. Time comes in as a `Timestamp` argument
  (or a `now` parameter), so every timing rule can be tested without
  sleeping. Filesystem access only where the Swift reads files (title
  lookups, installers, user manifests), behind a path argument so tests can
  point it at a temp dir.
- **Cross-platform.** No macOS-only APIs. Use `std::path` for paths, never
  string `/` concatenation where a path is meant; HOME comes from an
  argument or `std::env::var_os("HOME")`/`USERPROFILE`.
- **Dependencies** are fixed in each crate's `Cargo.toml` and already in
  `Cargo.lock`. Do not add any. If one is truly needed, say so in your
  report instead.
- Do not touch files outside your crate's directory.
- The pane key is the **seahelmd session name**. Hook payloads carry
  `seahelm_pane_id`, which is either a session name or a client alias (the
  Swift app's `Station.id` UUID). The registry resolves both.

## seahelm-core-hooks

Swift sources: `Sources/Status/WebhookEvent.swift`, `HookDecoder.swift`,
`WebhookStatusProvider.swift`, `AgentWorkLocation.swift`,
`Sources/Core/StopHookResponder.swift`, `AgentSessionRef.swift`,
`SessionTitleLookup.swift`, `CodexSessionPromptLookup.swift`,
`CursorSessionTitleLookup.swift`, `UserPromptText` (wherever it lives),
`ActivityEventExtractor`, the event-sink steps in
`Sources/App/TabCoordinator.swift` (~lines 840-895), the installers
`SeahelmHookInstaller.swift`, `ClaudeHooksSetup.swift`,
`CodexHooksSetup.swift`, `CursorHooksSetup.swift`, `HookEventMerge.swift`,
`OpenCodePluginInstaller.swift`, `PiExtensionInstaller.swift`, and
`AgentHookInstaller.swift`.

```rust
pub mod event {
    pub struct WebhookEvent {           // WebhookEvent.swift
        pub source: String,             // "claude-code", "codex", "cursor", "opencode", "pi", …
        pub session_id: String,
        pub event: WebhookEventType,
        pub cwd: String,
        pub data: serde_json::Map<String, serde_json::Value>,
        pub session_path: Option<String>,
        pub pane_id: Option<String>,    // seahelm_pane_id
    }
    pub enum WebhookEventType { /* every case, with as_str() wire names */ }
    impl WebhookEventType { pub fn agent_status(&self, data: &Map) -> AgentStatus; }
    pub fn parse(payload: &serde_json::Value) -> Option<WebhookEvent>;
}
pub mod decode {
    /// HookDecoder: None for subagent_stop, cwd_changed, assistant_response.
    pub fn decode(ev: &WebhookEvent, now: Timestamp) -> Option<EventKind>;
}
pub mod sink {
    /// The event-sink steps the app runs before the provider and registry
    /// (TabCoordinator): Cursor assistant prose and the `::seahelm-suggest::`
    /// sentinel turned into synthetic `suggest` events, sentinel stripped.
    /// Returns the events to process, in order.
    pub fn expand(ev: WebhookEvent) -> Vec<WebhookEvent>;
    /// SubagentStart → Some(true); Stop/SubagentStop → Some(any background
    /// task running); else None (AgentRegistry.updateBackgroundBusy).
    pub fn background_busy(ev: &WebhookEvent) -> Option<bool>;
    /// Whether a `suggest` event is dropped because the worktree is busy.
    pub fn drops_suggest(ev: &WebhookEvent, worktree_busy: bool) -> bool;
}
pub mod location { /* AgentWorkLocation: signal(), created_worktree() */ }
pub mod provider {
    /// WebhookStatusProvider without queues or callbacks: one call per
    /// event, everything it would have called back with returned.
    pub struct Provider { /* sessions, last tool targets, created worktrees, throttle */ }
    pub struct Output {
        pub worktree_status: Vec<(String /*worktree*/, AgentStatus)>, // changed rollups
        pub new_worktree: Option<(String /*canonical path*/, Option<String> /*pane*/)>,
        pub pane_location: Option<PaneLocation>,
        pub session_ref: Option<(String /*pane*/, session_ref::AgentSessionRef)>,
        pub user_prompt: Option<String>,
        pub tasks: Option<Vec<TaskItem>>,
    }
    pub struct PaneLocation { pub pane: String, pub worktree: Option<String>, pub location: String, pub created_by_agent: bool }
    impl Provider {
        pub fn new() -> Self;
        pub fn set_worktrees(&mut self, paths: &[String], now: Timestamp);
        /// `is_worktree_root` is the filesystem probe (`<path>/.git` exists),
        /// injected so tests need no disk and a slow volume can time out.
        pub fn handle(&mut self, ev: &WebhookEvent, now: Timestamp,
                      is_worktree_root: &mut dyn FnMut(&str) -> bool) -> Output;
        pub fn match_worktree(&self, path: &str) -> Option<String>; // longest prefix
    }
}
pub mod session_ref { /* AgentSessionRef: serde shape of config.json agent_sessions; resume/fork argv */ }
pub mod titles { /* claude(home, cwd, session_id), codex_prompt(home, id), cursor(home, cwd, chat_id) */ }
pub mod suggest { /* StopHookResponder: parse_suggestions, strip_sentinel, SENTINEL */ }
pub mod install {
    /// Each installer as a pure reconcile (old file contents → new, or None
    /// when unchanged) plus a thin `install_*(home: &Path, hook_cmd: &Path)`.
    /// The hook command is the Rust `seahelm-hook` binary's path.
}
// src/bin/seahelm-hook.rs: reads the hook JSON on stdin, argv[1] = source;
// splices "seahelm_pane_id" (SEAHELM_PANE_ID, else SEAHELMD_SESSION) and
// "seahelm_source"; sends {"jsonrpc":"2.0","id":"h","method":"hook","params":…}
// as one line to $SEAHELM_SOCKET_PATH (default ~/.config/seahelm/seahelm.sock;
// on Windows a named pipe path). Fire-and-forget, 2 s timeout, always exit 0,
// never writes to stdout.
```

Tests: `WebhookEventTests`, `HookDecoderTests`, `WebhookStatusProviderTests`,
`AgentMovedWorktreeTests`, `AgentWorkLocationTests`,
`WebhookTaskParsingTests`, `WebhookSuggestEventTests`,
`StopHookResponderTests`, `AgentSessionRefTests`, `SessionTitleLookupTests`,
`CursorSessionTitleLookupTests`, `SeahelmHookInstallerTests` (adapted to
the binary), `ClaudeHooksSetupTests`, `CodexHooksSetupTests`,
`CursorHooksSetupTests`, `HookEventMergeTests`,
`OpenCodePluginInstallerTests`, and the Pi installer tests, if any.

## seahelm-core-scan

Swift sources: `Sources/Status/StatusDetector.swift` (detector, tracker,
AgentDef fallback only if a production path still uses it),
`AgentManifest.swift`, `ManifestEngine.swift`, `ManifestStore.swift`,
`ProcessProbe.swift`, `ChoiceOptionParser`, the activity regexes, the
per-pane flow of `StatusPublisher.swift` (`pollAll`, `resolveAgentType`,
`shouldSkipUnchangedFrame`, `roundStart`, `idleObservation`), the scan half
of `SeahelmControlDataSource.explainPane` / `matchDetail`, and the bundled
manifests in `Resources/Manifests/*.json`. Copy those into
`crates/core-scan/manifests/` and embed them with `include_str!`.

```rust
/// seahelmd's `snapshot` JSON (see seahelmd/README.md).
#[derive(Deserialize)] pub struct Snapshot {
    pub started: Option<bool>, pub generation: u64, pub cols: u16, pub rows: u16,
    pub alt_screen: bool, pub title: String, pub pwd: String,
    pub progress: Option<Progress /* state, percent */>,
    pub program_seq: u64, pub program: Option<seahelm_core_types::ProgramStatus>,
    pub viewport: String,
}
pub mod manifest {
    pub struct ManifestStore;  // bundled + user overrides (by id, aliases), deterministic order
    impl ManifestStore {
        pub fn bundled() -> Self;
        pub fn with_user_dir(dir: &Path) -> (Self, Vec<String> /*load errors*/);
        pub fn get(&self, id_or_alias: &str) -> Option<&CompiledManifest>;
        pub fn authority(&self, agent: AgentType) -> Authority;
    }
    // Invalid regexes are load errors, not silently dropped.
}
pub mod detect { pub struct Detection { … }; pub fn detect(…) -> Detection; }
pub mod debounce { pub struct DebouncedStatusTracker; }
pub mod choices  { /* ChoiceOptionParser */ }
pub mod process {
    pub struct ProcessTable;                    // one capture per poll cycle (sysinfo)
    impl ProcessTable { pub fn capture() -> Self; }
    pub struct Probe { pub agent: Option<AgentType>, pub saw_session: bool,
                       pub foreground_command_line: Option<String>, pub memory_bytes: u64 }
    pub fn probe(table: &ProcessTable, root_pid: u32, store: &ManifestStore) -> Probe;
}
pub mod pane {
    /// One pane's scan state across polls: StatusPublisher's per-pane flow.
    pub struct PaneScanner;
    pub struct ScanInput<'a> {
        pub snapshot: &'a Snapshot,
        pub hook_status: AgentStatus,
        pub hook_turn_started: Option<Timestamp>,
        pub probe: Option<&'a Probe>,
        pub current_agent: AgentType,
        pub now: Timestamp,
    }
    pub struct ScanOutput {
        pub event: Option<EventKind>,            // ScreenObserved, when something changed
        pub agent_type: AgentType,               // what the pane is running (updateDetection)
        pub command_line: Option<String>,
        pub question: Option<EventKind>,         // approval dialog → Question (ChoiceOptionParser)
    }
    impl PaneScanner {
        pub fn new() -> Self;
        pub fn observe(&mut self, input: &ScanInput, store: &ManifestStore) -> ScanOutput;
        pub fn invalidate(&mut self);            // a hook arrived: rescan next poll
    }
}
pub mod explain {
    /// The scan fields of `pane.explain`: agent, manifest, manifest_version,
    /// authority, scan_status, scan_defaulted, background_busy, osc_title,
    /// osc_progress, matched_rule {id,state,priority,region,evidence} or
    /// default_status.
    pub fn explain(snapshot: &Snapshot, agent: AgentType, store: &ManifestStore) -> serde_json::Value;
}
```

Tests: `StatusDetectorTests`, `ManifestEngineTests`, `StatusPublisherThreadTests`
(the per-pane logic; not the threading), `AgentTypeResolutionTests`,
`ProcessProbeTests` (logic that does not need a live process tree; a few
tests against the test process itself are fine), `ChoiceOptionParserTests`,
`StatusDetectorActivityTests`, and `MessageConfigManifestTests`.

## seahelm-core-registry

Swift sources: `Sources/Core/AgentRegistry.swift` (`ingest`,
`arbitrateDetailed`, grace and reclaim windows, `handleWebhookEvent` pane
resolution and adoption, `updateDetection`, background busy, activity
events, `setUnseenCompletion`, `rehome`), `PaneInfo.swift`,
`UnseenCompletion.swift`, `Sources/Status/WorktreeStatusAggregator.swift`,
`PaneStatus.swift`, `Sources/Core/EventHub.swift`, the decision half of
`Sources/Status/NotificationManager.swift` (`shouldNotify`: fingerprint
dedupe, 30 s cooldown, 1 s stability gate), and the completion logic in
`TabCoordinator.deliverPaneStatusChange` / `deliverAgentCompletion` that
decides (not delivers).

```rust
pub struct PaneInfo { /* every field PaneInfo.swift has, minus `station`/`channel`;
                         plus `alias: Option<String>` */ }
pub struct Registration { pub pane: String, pub alias: Option<String>,
                          pub worktree_path: String, pub project: String, pub branch: String,
                          pub agent_type: AgentType, pub started_at: Option<Timestamp> }
pub struct Outcome { /* what AgentRegistry's onOutcome carried: pane, event kind,
                        old/new status, status_changed, is_completion_signal, seq,
                        hold_seconds, … */ }
pub struct Registry;
impl Registry {
    pub fn new() -> Self;
    pub fn register(&mut self, r: Registration, now: Timestamp);
    pub fn unregister(&mut self, pane: &str, now: Timestamp);
    pub fn rehome(&mut self, pane: &str, worktree: &str, branch: &str, project: &str, now: Timestamp);
    /// seahelm_pane_id (session or alias) first, else the pane of the worktree
    /// whose path is the longest prefix of `cwd`; adopts a live unregistered
    /// pane as the Swift does.
    pub fn resolve(&self, pane_hint: Option<&str>, cwd: &str) -> Option<String>;
    pub fn ingest(&mut self, ev: NormalizedEvent, authority: Authority, now: Timestamp) -> Option<Outcome>;
    pub fn update_detection(&mut self, pane: &str, agent: AgentType, command_line: Option<String>);
    pub fn set_background_busy(&mut self, worktree: &str, busy: bool);
    pub fn set_unseen(&mut self, pane: &str, unseen: bool, now: Timestamp) -> bool;
    pub fn pane(&self, pane: &str) -> Option<&PaneInfo>;
    pub fn panes(&self) -> impl Iterator<Item = &PaneInfo>;  // registration order
    pub fn hook_status(&self, pane: &str) -> AgentStatus;
    pub fn turn_started(&self, pane: &str) -> Option<Timestamp>;
    /// pane.explain's arbitration fields: status, decided_by, scan_status,
    /// hook_status, hook_idle_fresh, program_status_live, program_status.
    pub fn explain(&self, pane: &str, authority: Authority, now: Timestamp) -> serde_json::Value;
    /// One pane as pane.list reports it (PaneSnapshot.dict).
    pub fn pane_json(&self, pane: &str) -> Option<serde_json::Value>;
    pub fn events(&self) -> &EventHub;
}
pub mod rollup  { /* WorktreeStatus (recency rule), highest-priority rule, last activity */ }
pub mod unseen  { pub fn marks(old: AgentStatus, new: AgentStatus) -> bool; pub fn clears(new: AgentStatus) -> bool; }
pub mod notify  { /* NotificationPolicy: should_notify(...) -> Decision */ }
pub mod events  {
    pub struct EventHub;   // 500-entry ring keyed by seq
    impl EventHub { pub fn events_after(&self, seq: u64) -> Vec<serde_json::Value>; pub fn current_seq(&self) -> u64; }
    // Event JSON exactly as the Swift publishes: pane.status_changed,
    // pane.updated, pane.closed, pane.rehomed, pane.unseen_changed.
}
```

Fix the bug the port found: the aggregator rebuild dropped
`background_busy`. The registry's own cwd fallback uses the **longest**
prefix.

Tests: `AgentRegistryIngestOutcomeTests`, `AgentRegistryTests` (the parts
that are not `updateStatus`), `AgentRegistryWebhookPathTests`,
`AgentRegistryIngestTests`, `AgentRegistryTransitionTests`,
`AgentRegistryBackgroundBusyTests`, `AgentRegistryActivityEventTests`,
`PaneInfoDisplayStatusTests`, `PaneStatusTests`,
`WorktreeStatusAggregatorTests`, `UnseenCompletionTests` (registry parts),
`EventHubTests`, and `NotificationManagerTests` (decision parts).
