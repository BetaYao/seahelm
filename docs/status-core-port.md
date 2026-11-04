# Porting agent status detection to `seahelm-core`

Status: implemented through M5 on macOS (see "Implementation status" at the end); Windows transport pending. Written 2026-11-03 from a read of the Swift sources at
80e01c1. Line references are to that commit.

## Why

The GPUI client (`clients/gpui`) is meant for Windows and Linux. At the moment
it gets fleet and status data from the running macOS app's control socket,
and on those platforms there is no such app. Status detection is the core
of seahelm and the hardest part of it, so it moves first. The target is a
headless Rust service, `seahelm-core`, that every client talks to: the
GPUI client, the web gateway, and eventually the Swift app. It speaks the
JSON-RPC methods that already exist (`pane.list`, `pane.explain`,
`events.subscribe`, the `fleet.groups` status fields). The detection logic
then exists once rather than once per platform.

## What exists today (summary)

About 9k lines of Swift take part in deciding a pane's status. They form
three paths that meet in `AgentRegistry`:

```
hooks:   agent ──seahelm-hook (sh + nc -U)──▶ seahelm.sock "hook" ─▶ WebhookEvent.parse
           ─▶ event-sink queue ─▶ WebhookStatusProvider (cwd→worktree, tasks, location)
                               └▶ AgentRegistry.handleWebhookEvent ─▶ HookDecoder ─▶ ingest
scan:    StatusPublisher (2s timer) ─▶ Ghostty viewport text + OSC title/progress
           ─▶ ProcessProbe (seahelmd list + sysctl) ─▶ StatusDetector (manifests)
           ─▶ DebouncedStatusTracker ─▶ ChoiceOptionParser ─▶ ingest(.screenObserved)
program: Ghostty OSC 7501 ─▶ ingest(.programStatus)

ingest ─▶ arbitrateDetailed (7501 > urgent > manifest authority, grace/reclaim windows)
       ─▶ onOutcome (main) ─▶ WorktreeStatusAggregator, notifications, unseen completion,
                              Telegram, First Mate, EventHub ─▶ events.subscribe, gateway
```

The parts that are pure logic depend only on Foundation, not on AppKit or
Ghostty: hook parsing, the provider, location tracking, session references,
title lookups, the manifest engine, the detector, the tracker and the
arbitration. The parts that are tied to the app are `Station`/`StationRegistry` (pane
identity and screen reads), `NSColor` on `AgentStatus`, "on screen"
(`NSApp.isActive` plus the selection), and the main-queue fan-out.

### The code disagrees with CLAUDE.md, and some of it is dead

These are porting decisions, not things to copy blindly. They should be
settled first:

| Finding | Where | Port decision |
|---|---|---|
| OSC 133 shell phase is never fed: `shellInfo: nil` everywhere | StatusPublisher.swift:386 | Leave it out of v1. Add it later from the daemon, since libghostty-vt tracks semantic prompts |
| "Preferred worktrees every cycle, others every 3rd" is never used: preferred set is always `[]` | TabCoordinator.swift:344 | Poll every pane every cycle, as in practice today |
| `AgentRegistry.delegate` is never assigned | AgentRegistry.swift | Do not port |
| `PaneReducer` / `updateStatus` are called only from tests | PaneReducer.swift | Do not port; `ingest` is the write path |
| `PendingTransferTracker` is never instantiated | PendingWorktreeTransfer.swift | Do not port |
| `ScanDecoder` is unused; the publisher builds events inline | ScanDecoder.swift | Do not port |
| `CwdChanged` is still installed; CLAUDE.md says it must not be | ClaudeHooksSetup.swift:22-34 | Keep it as the code does; fix CLAUDE.md |
| seahelm-hook has no HTTP fallback and no Stop stdout relay any more | SeahelmHookInstaller.swift | Port the current behaviour |
| The surface-less fallback reads only the first 256 KB of `seahelmd history`, then the last 60 lines, so long scrollback means stale text | ProcessRunner.swift:187 | Fixed by design: core asks the daemon for the viewport |
| Rollup: row dot and header count use the most recently changed pane; grouping uses highest priority | PaneStatus.swift, WorktreeGrouping.swift:94 | Keep both in v1 for parity; decide later (open question 2) |
| The aggregator rebuild drops `backgroundBusy` | WorktreeStatusAggregator.swift:139 | Fix in the port |
| Registry pane fallback matches cwd by first prefix; the provider uses the longest prefix | AgentRegistry.swift:957 vs WebhookStatusProvider.swift:357 | Use the longest prefix everywhere |
| `ManifestStore.all` order is undefined, which changes process identification when two manifests match | ManifestStore.swift | Order deterministically: user overrides, then bundled, by id |
| Invalid manifest regexes are dropped silently | AgentManifest.swift:212 | Reject them at load with an error that `pane.explain` shows |
| `ghostty_surface_process_exited` reflects the `seahelmd attach` client, not the agent | Station.swift:693 | Take exit from the daemon instead |

## Target design

### Process and placement

- A crate and binary `seahelm-core` in the `seahelmd/` cargo workspace. It
  shares `keep-vt` and `seahelmd::proto` with the daemon.
- One per user, long-lived, started on demand by the first client the way
  seahelmd sessions are, and it outlives the clients. It listens on
  `~/.config/seahelm/core.sock` (a named pipe on Windows) and speaks the
  existing newline-delimited JSON-RPC.
- Single-threaded state behind an actor (one task owns the registry). Scans
  and file lookups run on a worker pool. No UI thread exists, so the Swift
  code's main-queue hops disappear.

### Pane identity

The core keys panes by **seahelmd session name**. That name is stable across
app restarts and is the same for every client. Today's `Station.id` UUID
becomes a client-side alias:

- `pane.register {session, worktree_path, pane_id?, agent_type?}` is called
  by whoever owns the layout. That is the Swift app or the GPUI client today,
  and the core itself once it owns layouts.
- `pane.unregister {session}`, and `pane.rehome {session, worktree_path}`,
  which keeps timers, as `AgentRegistry.rehome` does now.
- The hook shim already sends `SEAHELM_PANE_ID`, else `SEAHELMD_SESSION`.
  The core resolves either through the alias table.
- `worktrees.set {paths}` is the set of known worktrees for cwd matching,
  until fleet discovery also moves (a separate milestone).

### Screen source: ask the daemon

The core reads each session's screen from seahelmd, not from a renderer.
That works the same on every platform and for panes nobody is looking at.

v1 adds one request to the daemon protocol (`proto.rs`):

```
Msg::Snapshot  →  Msg::Snapshot{
    generation: u64,         // bumps on every parsed write; lets the core skip unchanged screens
    cols, rows,
    viewport: String,        // plain text of the visible screen only, rows joined by \n
    title: String,           // OSC 0/2 — keep-vt already tracks it (Terminal::title)
    progress: Option<(u8,u8)>, // OSC 9;4 state;percent
    alt_screen: bool,
    exited: Option<i32>,     // the program's exit status, once it has one
}
```

This replaces the current reads: the Ghostty viewport read under
`ghosttyLock`, and the `seahelmd history` subprocess with its 256 KB cap.
The 2s poll and the change detection stay. The hash is replaced by
`generation`, while the 15-cycle forced recheck and the "never skip when the
hook says idle but the scan says running" rule stay.

v2 (optional) adds `Msg::Watch`: an observer attachment that receives
`Repaint`, `Output` and a new `Resized`. It is never counted as a viewer for
size negotiation or for answering terminal queries; today's
`subscribers.is_empty()` check would have to count viewers only. With it the
core keeps a grid per session and sees edge events the poll misses: OSC 7501
program status, and OSC 133 exit codes. Leave it out of v1 unless 7501 is
needed. 7501 also needs keep-vt to parse it, because today Ghostty's patched
bridge does.

### Process identification

Port `ProcessProbe.identify` (exec names, then `argv_contains` behind a
generic runtime) on top of the `sysinfo` crate. It provides the pid tree and
argv on macOS, Linux and Windows. The root pid comes from the daemon's
`Info`. This replaces `sysctl KERN_PROC_ALL` / `KERN_PROCARGS2` and the
`seahelmd list` fork per cycle.

### Hooks transport

- Replace `~/.local/bin/seahelm-hook` (`/bin/sh` and Apple `nc -U`) with a
  small Rust binary. It is cross-platform (Unix socket, or a named pipe on
  Windows), keeps the same argv (`seahelm-hook <source>`) and the same
  payload splice, and stays fire-and-forget with exit 0. The same binary can
  replace the python3 `seahelm` CLI later.
- During migration the Swift app's `"hook"` method forwarded the payload
  to core.sock in addition to handling it. That is replaced (M6): the
  bridge sends to both sockets itself, so the core hears hooks while the
  app is closed, and machines without the app use `seahelm-core hook`.
- Port the installers as pure merge functions with their tests:
  `HookEventMerge`, Claude, Codex (TOML features plus hooks.json), Cursor,
  OpenCode (plural `plugins/`, per-session `info.directory`) and Pi. On
  Windows the commands must not use `/bin/sh -lc`, and the OpenCode and Pi
  plugins call the shim binary instead of `nc`.

### Module map (Swift → Rust)

| Rust module | From | Notes |
|---|---|---|
| `hooks::event` | WebhookEvent.swift (291) | 3 payload shapes; declared source wins over key sniffing |
| `hooks::decode` | HookDecoder.swift (135) | AskUserQuestion → question, "(i/N)", review flag on the last |
| `hooks::provider` | WebhookStatusProvider.swift (426) | Session state, longest-prefix match, tasks, 1h prune, 15s discovery throttle, worktree-root probe with timeout counted as false |
| `hooks::location` | AgentWorkLocation.swift (116) | `cd`/Edit target, `git worktree add` / EnterWorktree creation |
| `hooks::install` | the *HooksSetup / installers (~1000) | Pure merges plus file I/O |
| `sessions::refs` | AgentSessionRef.swift (209) | Resume and fork argv tables, validation |
| `sessions::titles` | SessionTitleLookup, Codex/Cursor lookups (~520) | Claude jsonl scan; Codex sessions; Cursor `meta.json`/`store.db` (rusqlite, md5 of cwd) |
| `scan::manifest` | AgentManifest/Engine/Store (~570) + Resources/Manifests (12 json) | `regex` crate; every pattern is compatible; reject bad patterns |
| `scan::detect` | StatusDetector.swift (362) | Ladder minus the unused shell tier; activity extraction |
| `scan::debounce` | DebouncedStatusTracker | 2 / 6 confirmations, visible-idle bypass |
| `scan::choices` | ChoiceOptionParser | Approval prompt forces waiting and yields a question |
| `scan::process` | ProcessProbe.swift (398) | On `sysinfo` |
| `scan::poller` | StatusPublisher.swift (688) | 2s, change skip, 15-cycle recheck, process refresh every 5 |
| `registry` | AgentRegistry.swift (1471) + PaneInfo (136) | `ingest`, `arbitrate`, grace/reclaim (3s/15s/3s/3s), background busy, activity log (20), unseen completion |
| `rollup` | WorktreeStatusAggregator (175) + PaneStatus | Both rollup rules, last activity |
| `notify` | NotificationManager.shouldNotify | Decision only: fingerprint dedupe, 30s cooldown, 1s stability gate. Clients deliver |
| `events` | EventHub (55) | 500-entry ring, `events_after` replay, `events.subscribe` |
| `rpc` | ControlProtocol / SeahelmControlDataSource (status methods) | `pane.list`, `pane.explain`, `pane.seen`, `pane.wait_agent_status`, `hook`, `suggest`, `events.subscribe`; `pr.list` (M7) |
| `pr` | WorktreePRStatus.swift (WorktreePRStore, WorktreePRStatusParser) | `crates/core/src/pr.rs`; curl transport, see M7 |

### What stays in clients

- Colours and drawing (`AgentStatus.color`).
- "On screen". A client reports `client.visible {worktrees, app_active}`;
  the core marks and clears unseen completion from it, and from `pane.seen`.
- Delivering notifications: UserNotifications on macOS, toast on Windows,
  libnotify on Linux. The core emits a "notify" decision event.
- Acting on location changes (fork / auto-fork, repo auto-add). The core
  publishes `pane.location {session, worktree, location, created_by_agent}`,
  as `onPaneWorktreeResolved` does today. Moving these actions into the core
  belongs to the layout milestone.
- For now: Telegram, First Mate and the gateway keep consuming events, which
  now come from the core's `events.subscribe` instead of `onOutcome`.

## Verification

1. **Swift tests as the spec.** Port the tests that pin behaviour to Rust
   unit tests, with case names kept so the two can be compared:
   - Hooks: WebhookEvent, HookDecoder, WebhookStatusProvider,
     AgentMovedWorktree, AgentWorkLocation, WebhookTaskParsing,
     WebhookSuggestEvent, StopHookResponder, AgentSessionRef,
     SessionTitleLookup, CursorSessionTitleLookup, and the installer tests.
   - Scan: StatusDetector, ManifestEngine, StatusPublisherThread,
     AgentTypeResolution, ProcessProbe, ChoiceOptionParser,
     StatusDetectorActivity, MessageConfigManifest.
   - Model: AgentRegistryIngestOutcome, AgentRegistry, AgentRegistryWebhookPath,
     AgentRegistryBackgroundBusy, AgentRegistryActivityEvent, PaneInfoDisplayStatus,
     PaneStatus, WorktreeStatusAggregator, UnseenCompletion, EventHub,
     NotificationManager (decision part).
2. **A screen corpus.** Today there are no screen fixtures; every screen is
   an inline string. Capture real viewports from live panes over a few days
   (Claude, Codex, Cursor, OpenCode; running, waiting on approval, idle,
   error) together with what `pane.explain` decided. These become golden
   tests for the Rust engine.
3. **Shadow mode.** Run the core next to the macOS app, with hooks forwarded
   and the core scanning the same sessions. A comparator polls `pane.list` on
   both sockets every 2s and logs every pane where the two disagree for longer
   than the grace windows. Run it for a few days of real work and fix each
   class of divergence before any client trusts the core.

## Milestones

| | Scope | Estimate |
|---|---|---|
| M0 | seahelmd `Snapshot` (viewport, title, progress, alt, generation, exit, 7501 root record); OSC 7501/133/9;4 scanning, 7501 parser and record store in keep-vt; 7501 query answered while detached; tests | 4–5 d |
| M1 | Core skeleton, RPC server, `pane.register`/`worktrees.set`, manifests, detector, debounce, choices, process identification, poller, `pane.explain`; scan tests ported; `seahelm-core scan <session>` for debugging | 5–6 d |
| M2 | Rust `seahelm-hook`; event parsing, decoder, provider, location, session refs and title lookups; hook tests ported; Swift app forwards `hook`/`suggest` | 4–5 d |
| M3 | Registry: ingest, arbitration, grace and reclaim, unseen completion, rollups, notify decision, EventHub and `events.subscribe`, `pane.list` / `pane.seen` / `pane.wait_agent_status`; model tests ported | 4–5 d |
| M4 | Screen corpus and shadow comparator; divergences fixed | 3–5 d |
| M5 | GPUI client reads from the core; installers ported; Windows named pipe for core and shim | 3–4 d |

About 4–5 weeks for M0–M4. Moving the Swift app's own consumers onto the
core is a separate plan, written after shadow mode has shown the core is
right.

## Decisions (2026-11-03)

1. **Pane identity** is the seahelmd session name; `Station.id` is a client
   alias.
2. **Rollup**: v1 keeps both rules (recency for the row dot and header count,
   priority for grouping) for parity. Unifying them is a later product call.
3. **Core lifecycle**: started on demand by the first client, outlives
   clients, like seahelmd sessions.
4. **OSC 7501 is in v1.** It goes through the daemon rather than a `Watch`
   path. Each seahelmd session scans its output for OSC 7501, OSC 133 `D`
   (the shell has the terminal back) and OSC 9;4 (progress). It keeps the
   7501 records (`ProgramStatusStore`, ported from
   `Sources/Status/ProgramStatus.swift`) and reports the live root record
   in `Snapshot` with a sequence number, so the core sees every change of
   the root even between polls. While nobody is attached, the daemon also
   answers the `OSC 7501 ; ?` support query, as it answers OSC 10/11.
   Claude Code only reports 7501 to a terminal that has answered it, so an
   agent started detached would otherwise never report. Attached clients
   answer it themselves: Ghostty through seahelm's patch, and the GPUI client
   through the same keep-vt code. The parser is a Rust port of
   `scripts/ghostty-patches/0001-osc7501-program-status.patch`
   (`program_status.zig`), and that file's tests come with it.

## Implementation status (2026-11-03)

| | State |
|---|---|
| M0 | Done. `seahelmd snapshot`, OSC 7501 / 133 / 9;4 scanning, the 7501 store, the 7501 support query answered while detached, and answered *in order* with the queries around it (Claude Code reads the DA1 answer as "nothing else is coming"). Verified against a real detached Claude Code: `idle` → `working` → `done`. |
| M1–M3 | Done as four crates (`docs/core-crates.md`): `seahelm-core-types`, `seahelm-core-hooks` (241 tests), `seahelm-core-scan` (127), `seahelm-core-registry` (143). Each ports its Swift tests by name. |
| core binary | `seahelm-core` (`serve`, `ensure`, `call`, `shadow`, `hook`, `install-hooks`, `version`): JSON-RPC on `~/.config/seahelm/core.sock` with `hook`/`suggest`, `pane.register`/`unregister`/`sync`, `worktrees.set`, `client.visible`, `pane.seen`, `pane.list`, `pane.explain`, `worktree.list`, `pane.locations`, `agent.sessions`, `pane.wait_agent_status`, `events.subscribe` (replay + stream). Completion decisions as the app makes them (unseen marking, held completions while the hooks still say running, the notification policy's dedupe / cooldown / stability gate) end in a `pane.notice` event for clients to show. Polls every registered pane's `snapshot` every 2 s. Sessions from a seahelmd older than `Snapshot` fall back to the tail of `history`, every third cycle. |
| M4 | Shadow mode in place: hooks reach the core (first forwarded by the app, now sent by the bridge itself, see M6), and `seahelm-core shadow --follow-app` mirrors the app's panes into the core and logs every disagreement that outlasts 8 s to `~/.config/seahelm/core-shadow.jsonl`. |
| M5 | The GPUI client starts the core, registers the panes it opens, reports what it shows, and takes each worktree's dot from the core where the core has one. The installers and the Rust `seahelm-hook` are ported (`seahelm-core-hooks::install`, `src/bin/seahelm-hook.rs`); nothing installs them yet, since the app still installs its own shim. |
| M6 | Hooks reach the core with no app in between. The app's `seahelm-hook` (v7) sends each payload to `core.sock` as well as `seahelm.sock`, and the app no longer forwards (`CoreHookForwarder` is gone, so nothing arrives twice). Without the app, `seahelm-core install-hooks` wires Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`, `[features].hooks`) to `seahelm-core hook <source>`, a bridge with the shim's contract (the `wire` splice, no stdout, exit 0, 2 s watchdog) that talks to the core's socket or, on Windows, its named pipe. It leaves an event alone when it already runs `seahelm-hook`, migrates its own entry when the exe moves, and never touches anyone else's. |
| M7 | PR and CI status in the core (`crates/core/src/pr.rs`, ported from the app's `WorktreePRStore` / `WorktreePRStatusParser`, tests ported by name). Per repository, at most once a minute, the 30 most recently updated PRs (head branch, state, draft, review decision, head commit's check rollup) through `curl` to GitHub's GraphQL API, the request in a config on stdin so the token is not in argv; PRs from forks skipped; filed by branch. Token: `$GITHUB_TOKEN`, `$GH_TOKEN`, else `gh auth token`; none means no request. A failed request keeps the last answer and retries after five minutes. It runs on its own thread with its own lock (`core-pr`, every 15 s), so GitHub never holds the registry. Worktrees watched: those `worktrees.set` lists plus every registered pane's; each branch is re-read every tick. `worktree.list` stays as it was (worktrees with panes only) and gains `pr` on those entries; every watched worktree with a PR is in the new `pr.list` (`{prs: [{worktree_path, repo, branch, pr}]}`), so a client that reads only `worktree.list` sees no new rows. `pr` is the app's `fleet.groups` item shape: `{number, url, state: open\|draft\|merged\|closed, checks?: passing\|failing\|pending, review?: approved\|changes_requested\|review_required}`, checks and review only while open or draft. The GPUI client lists its fleet with `worktrees.set` and draws the app's badge from `pr.list`. |
| M8 | The core logs what it decides (`~/.config/seahelm/core-events.jsonl`: status changes, notices, closes, moves, unseen completions, each with its wall-clock time; a scratch core on `$SEAHELM_CORE_SOCKET` logs beside its socket). The GPUI client follows `events.subscribe`: status changes refresh its rows at once, `pane.notice` becomes a banner (osascript / notify-send / a WinRT toast), and it reports its window's activation with `client.visible`. Windows: the core and the bridge use named pipes (`\\.\pipe\seahelm-core-<user>`), built and tested in Windows CI. `scripts/ab/` records a stretch of the app and the GPUI client used side by side and reports on it. |
| M9 | Claude's and Codex's rate limits and today's tokens (the app's `Sources/Usage`) are a core service. `usage.summary` returns both snapshots (`rate_limit`, `weekly_rate_limit`, `today_tokens`, `updated_at`, `is_stale`) and the readouts (`segments`: `label`, `percent_text`, `severity`, `reset_text`). A thread of its own refreshes them every 60 s, and each field falls back to its last reading for 10 min (`crates/core/src/usage.rs`; the providers' and store's tests are ported by name). Claude's figures come only from the statusline payload cache: `~/Library/Caches/seahelm/claude-statusline.json` on macOS, so the app's bridge keeps feeding it; `$XDG_CACHE_HOME/seahelm` on Linux; `%LOCALAPPDATA%\seahelm\cache` on Windows. Codex's come from `codex app-server` and `~/.codex/sessions`. Without the app, `install-hooks` also wraps Claude's `statusLine` in `seahelm-core statusline -- '<original>'` (`statusline.rs`), which caches a payload that carries rate limits, then runs the original on the same bytes and passes its output and status through. The original command stays in the settings after `--`; the app's bridge is left alone. The GPUI client shows the readout at the foot of the fleet column. |

Found while porting, beyond the table above:

- The process probe assumed the session root is a shell. A session can run
  its agent as its own program (`seahelmd new NAME -- claude`, which the
  GPUI client uses), so the root is now read too, and set aside only when it
  is a shell. A login shell's argv0 (`-zsh`) now counts as a shell.
- A core started by a client that ignores SIGTERM inherited that and could
  not be stopped. `serve` restores the default handlers, and unblocks
  SIGTERM and SIGINT: a blocked mask survives exec as well, so a core the
  GPUI client started would not stop on SIGTERM.

Still open:

- **Windows.** The core serves a named pipe (seahelmd's platform layer), and
  CI builds and tests it there, but none of this has been tried on a Windows
  desktop. Untested there: the hook bridge; the statusline tee, which runs
  the original command through `cmd /C` while Claude Code on Windows may use
  Git Bash; and `codex app-server` through an npm `.cmd` shim.
- **The app as a client of the core.** The app still decides status itself
  (the core gets hooks from the bridge, not from the app). Moving its consumers over (rows, island,
  notifications, Telegram, First Mate) is a separate plan, to be written once
  shadow mode has run for a few days of real work.
