# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Seahelm (sea + helm) is a native macOS terminal multiplexer built with Swift + AppKit. It integrates the Ghostty terminal engine (via C bindings through GhosttyKit.xcframework) to render terminals, uses zmx for session persistence, and provides a dashboard UI for browsing git worktrees with agent status detection.

## Build Commands

```bash
# First-time setup: init the Ghostty submodule + build/reuse GhosttyKit.xcframework
scripts/setup.sh

# Build into .build/, kill any running Seahelm, and launch the debug app
./run.sh                 # add --clean-restart to wipe .build first
./run.sh --onboarding    # force the first-launch wizard (passes --show-onboarding)

# Run UI tests (regenerates the project, optionally filtered to one class)
./run_ui_tests.sh [TestClass]
```

Note: `run.sh` builds with `-derivedDataPath .build`, so the live app runs out of `.build/`, NOT the default `~/Library/Developer/Xcode/DerivedData` bundle a bare `xcodebuild` or Xcode.app run would produce — when inspecting a running instance, use the bundle the live pid actually came from.

```bash
# Generate Xcode project from project.yml (requires xcodegen)
xcodegen generate

# Build
# NOTE: CodeEditSourceEditor pulls in the SwiftLint build-tool plugin, which
# requires trust validation. Headless/CLI builds must pass -skipPackagePluginValidation
# (in Xcode.app, click "Trust & Enable" once instead).
xcodebuild -project seahelm.xcodeproj -scheme seahelm -configuration Debug -skipPackagePluginValidation -skipMacroValidation build

# Run tests
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test

# Run a single test class
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/ConfigTests

# Run a single test method
xcodebuild -project seahelm.xcodeproj -scheme seahelmTests -configuration Debug test -only-testing:seahelmTests/ConfigTests/testDefaultConfig

# Run UI tests — prefer targeted unit classes during active development.
# The full seahelmUITests suite is slow AND hijacks the live app's control
# socket, freezing panes at "running". Avoid it unless you specifically need it.
xcodebuild -project seahelm.xcodeproj -scheme seahelmUITests -configuration Debug test

# Clean build
xcodebuild -project seahelm.xcodeproj -scheme seahelm clean
```

The project uses XcodeGen (`project.yml`) to generate the Xcode project file. After modifying `project.yml`, regenerate with `xcodegen generate`.

**Helper scripts:** since zmx underpins session persistence, several scripts manage the vendored `zmx` binary — `scripts/fetch-zmx.sh` (fetch the pinned arm64 binary to a dest, verifying its SHA-256), `scripts/check-zmx.sh` (check whether a newer release exists than `Vendor/zmx.pin`; exit 10 if so), `scripts/bump-zmx.sh <version>` (download + rewrite the pin, no commit), and root `zmx-cleanup.sh` (kill all zmx sessions). `scripts/install-hooks.sh` symlinks `scripts/hooks/` into `.git/hooks`.

## Architecture

**Four-layer design:**

1. **App Coordinators** (`Sources/App/`)
   - `MainWindowController` — Window owner, embeds content VCs, positions traffic lights, handles keyboard shortcuts via `SeahelmWindow` subclass
   - `TabCoordinator` — Orchestrates tab switching, repo VC lifecycle (cached in `repoVCs[repoPath]`), status update forwarding, and session state save/restore
   - `TerminalCoordinator` — Split pane operations (split, close, move focus, resize), worktree deletion, surface manager ownership
   - `PanelCoordinator` — Manages side panels (AI panel, notification panel)

2. **UI Layer** (`Sources/UI/`)
   - `Dashboard/` — One layout, left/right (`setupLeftRightLayout`, accessibility id `dashboard.layout.left-right`): the fleet overview on one side as navigator, a `FocusPanelView` hosting the selected terminal on the other. `DashboardOverviewView` is that overview — every worktree a row, grouped by `WorktreeGroupingMode` (repository, status, activity time, or `pane`, which expands to a third level of pane rows). Edit mode swaps in `EditLayoutContainerView`: a terminal column and a file-preview column, each with an `EditTabStripView`, split by a draggable divider. The former Grid / TopSmall / TopLarge modes and the mini-card sidebar are gone; the "grid-aware" wording left in `DashboardFocusController` is a remnant, not a feature.
   - `Repo/` — `RepoViewController` with `SidebarViewController` for worktree switching; `SplitContainerView` hosts split panes
   - `Split/` — `SplitContainerView` renders `SplitTree` as frame-based leaf views with `DividerView` drag handles and dim overlays on unfocused panes
   - `Chrome/` — Two-column `WindowChromeController` (sidebar/terminal headers, divider, collapse)
   - `Dialog/` — Quick switcher (Cmd+P) and new branch dialog (Cmd+N)
   - `SidePanel/` — Per-worktree side panel with Files / Changes tabs (`WorktreeSidePanelViewController`). The old First Mate orders tab (`BridgePanelViewController`) and the inline command composer (`InlineWorktreeCreateView`) are gone: pending orders and the command line both live in `Island/`.
   - `Diff/` — Code-review diff viewer (`DiffReviewView` + `DiffSyntaxHighlighter`)
   - `Helm/` — `GrowingTextView` (extracted from the former `CommandInputView`), the keyboard-help overlay and the shortcut hint bar. The command line itself is the Island's (`Island/OpenedSurfaceView`, `/ @ #` autocomplete); the sidebar has no composer.
   - `StatusBar/` — Fixed 26pt bottom bar: mode indicator, global Claude/Codex usage, notification summary, shortcuts
   - `Island/` — Floating "dynamic island" panel (morphs closed pill ↔ open surface) for notifications/status
   - `Settings/`, `Onboarding/` — Tabbed settings window and the first-run wizard

3. **Core Services** (`Sources/Core/`, `Sources/Status/`)
   - `AgentRegistry` — Single source of truth for all agent state; delegates notify UI of changes
   - `StatusPublisher` — Timer-based polling (2s) on background queue, reads viewport text via `ghosttyLock`-protected C API calls
   - `StatusDetector` — Authoritative status detector. Priority: process exit > OSC 133 shell phase > text pattern matching > Unknown. Its text-pattern tier consults a `CompiledManifest` from the manifest engine (see below); the manifest layer augments, it does not replace, this ladder.
   - `WorktreeStatusAggregator` — Aggregates per-pane statuses into per-worktree status, fires `WorktreeStatusDelegate`
   - `Config` — JSON config at `~/.config/seahelm/config.json`; uses `decodeIfPresent()` for backward compat (migrated from legacy ~/.config/amux on first launch)
   - `StationRegistry` — Global registry mapping surface IDs to `Station` instances
   - `ExternalChannel` — Protocol for inbound remote-control chat. `TelegramChannel` is the live one: a Bot API bridge (`TelegramBotAPI`, blocking calls) that long-polls `getUpdates` on a thread of its own and answers with `sendMessage`. Its transport is `/usr/bin/curl` in a child process, not URLSession: in this process URLSession requests to Telegram hung after the first one or two (no response, no error, timeouts not firing) while the same requests from a standalone process or curl never failed, and per-request sessions, a watchdog and shorter polls did not cure it. The token reaches curl through a 0600 config file, never an argument. No permissions and no local app, but it needs a bot token from @BotFather (`TelegramConfig.botToken`, kept in config.json beside the pairing secret). `TelegramConfig.allowedUsers` (numeric ids or `@usernames`) is a hard gate — empty obeys nobody — and it also decides what a message *is*: from an allowed user it is an order (in a private chat any text, in a group only a `/command`, since bare prose in a shared group must not steer an agent); from anyone else it is rule input for `TelegramRuleEngine` (a monitoring channel the bot sits in, a colleague in a group). There is no echo guard because a bot's own messages never come back as updates. Outbound goes through `TelegramFormatter`: the bridge's light markdown to Telegram HTML, chunked to 4096, resent flat if Telegram returns 400.

4. **Terminal & System** (`Sources/Terminal/`, `Sources/Git/`)
   - `GhosttyBridge` — Singleton wrapping the Ghostty C API (`ghostty.h` via bridging header)
   - `Station` — Wraps `GhosttyNSView` (NSView + Metal renderer + PTY); manages surface lifecycle, reparenting, and backend session attachment
   - `SplitTree` / `SplitNode` — Tree data structure for split pane layout; serializable for persistence in config
   - `WorktreeDiscovery` — Runs `git worktree list --porcelain` to discover worktrees

## Key Patterns

**Surface lifecycle:** Station instances are long-lived — created once per split leaf, reparented between views (dashboard focus panel, repo tab split containers). `reparent(to:)` uses `CATransaction` to suppress animations, then defers size sync and focus restoration via two `DispatchQueue.main.async` passes. Surfaces are destroyed only on explicit deletion or app quit.

**Tab switching:** `detachActiveTerminal()` removes the active `SplitContainerView` from its superview before embedding the new tab's content. This prevents Z-order conflicts when surfaces are shared across views.

**Split pane system:** `SplitTree` is a binary tree of `SplitNode` (leaf or split with axis + ratio). `SplitContainerView.layoutTree()` computes frame-based positions for each leaf, places `GhosttyNSView` instances, adds `DividerView` drag handles, and updates dim overlays. Focus is tracked via `tree.focusedId`; `GhosttyNSView.onFocusAcquired` callback keeps the tree in sync when user clicks a pane.

**File drop:** dragging files (or an image out of a browser, Photos, Mail) onto a pane types their paths into *that* pane. `SplitContainerView` is the drag destination, not each `GhosttyNSView`: a `DividerView`'s 16pt hit strip overlaps the pane edges, and the container already knows every leaf frame. `draggingUpdated` resolves the pane under the cursor (`dropTargetStationId(at:paneFrames:)`; the seam goes to the nearest pane) and lights it with `GhosttyNSView.setDropHighlight`, an in-view sublayer like the inactive wash. Asleep panes, and panes covered by the preview overlay, refuse. `TerminalDrop.resolveText` takes the first of: file URLs → backslash-escaped paths (`ShellEscape.backslash`, native Ghostty's escaping) plus a trailing space; file promises → received into `$TMPDIR/seahelm-drops/<uuid>/`; bare image data → a PNG there; otherwise the dropped text verbatim. The text goes in through `Station.sendText` — `ghostty_surface_text`, the paste path, so bracketed paste applies and agent TUIs read a pasted image path as an image — and the drop focuses that pane and activates the app. In a pane whose agent is Claude Code (`AgentRegistry.pane(for:)`), dropped *images* attach instead of being typed (`AgentImagePaste`): each goes onto the general clipboard as PNG and the pane gets a real ctrl+v key event — Claude Code's `chat:imagePaste`, which reads the clipboard through `osascript … «class PNGf»` — then the user's clipboard is restored unless they copied in the meantime. It must be a key event, not `sendText`: inside a bracketed paste ctrl+v is just a pasted byte. Other files in the same drop follow as paths.

**Terminal persistence:** `runtimeBackend` is `"zmx"` (default) or `"local"` — there is no user-facing backend choice and no tmux backend. `MainWindowController` starts optimistically at `"zmx"` so early tree restore attaches persistent sessions before the async availability check lands, then falls back to `"local"` if zmx is missing. `local` panes are plain processes with no persistence (`SessionManager` guards `backend == "zmx"`). zmx sessions are named `seahelm-<parent>-<name>` (`.` and `:` replaced with `_`, truncated past `maxSessionNameLength`) and created per split leaf; a health check runs 3s after creation (`Station.recoveryDelay`) and stale sessions trigger `recoverZmxSession` (destroy + recreate). Split layouts are serialized to config for restore on relaunch.

**Pane follows its agent into a new worktree:** when an agent creates a worktree and starts working in it, that pane moves to the new worktree's card instead of the worktree standing up an empty pane beside it. The signal is the `cwd` **every** hook payload carries — not `CwdChanged`, which seahelm must not install (see `ClaudeHooksSetup.retiredHooks`: registering `WorktreeCreate` made Claude delegate worktree creation to us and broke `--worktree`, and `CwdChanged` alone cannot carry the case below). `WebhookStatusProvider.handleEvent` asks whether the cwd names a worktree it does not track: either it matches nothing, or — the case that used to be invisible — it sits *inside* a known worktree while being a worktree root itself, which is exactly where Claude Code's own `EnterWorktree` puts one (`<repo>/.claude/worktrees/<name>`). `matchWorktree` therefore takes the **longest** prefix, not the first. The detection is throttled per path and records a `PendingTransferTracker` entry keyed by canonical path plus the emitting `SEAHELM_PANE_ID`; when discovery integrates the worktree, `TabCoordinator.performPaneRehome` consumes it and moves **only that pane** (`StationManager.moveLeaf` → `SplitTree.removeLeaf`/`adopt`, keeping the Station and its zmx session), then `AgentRegistry.rehome` re-files the `PaneInfo` **without** unregister+register — which would reset the running agent's status, hook timers and event log. A worktree the pane arrives at gets its **placeholder retired rather than split**: if its only pane is one seahelm stood up itself this run (`StationManager.wasAutoCreated`, true for `tree(for:)`/`replacementTree` and false for a layout restored from config) and nobody has used it — no agent, no activity, `Station.showsOnlyPrompt == true` — `retirePlaceholderPane` destroys it and kills its zmx session, so the mover becomes the whole tree instead of landing beside an empty terminal. `showsOnlyPrompt` returns `nil` for "unknowable" (asleep, or an unreadable surface) and the policy treats nil as used: the pane is about to be thrown away, so it gets no benefit of the doubt. A worktree whose last pane left gets a replacement pane via `StationManager.replacementTree`, which claims a *free* zmx session name — the departed pane kept the worktree's canonical one (no rename in zmx), so reusing it would point two panes at one live session. **Two triggers, both keyed on that cwd.** The untracked-worktree check above only holds until discovery catches up, and the sweep runs every 5s (`branchRefreshTimer`) — an agent whose directory change is not itself a tool call (Codex's `/cd` fires no hook) reports its new cwd long after. So `onPaneWorktreeResolved` fires on *every* event naming a pane, and `TabCoordinator.followAgentToWorktree` moves the pane whenever the resolved worktree differs from its live `AgentRegistry` attribution. It is deliberately not edge-cached: the owner compares against the authoritative copy, so a move that could not complete yet is simply retried on the next event. Subagent events (`agent_id` present) are excluded — one running elsewhere must not drag its parent's pane.

**Two gates on the follow** (`TabCoordinator.shouldAutoFollow`, pure and unit-tested), because a cwd on its own says less than it looks like it does. *Same repo:* a pane follows its agent between worktrees of the repo it is working on; a cwd in an unrelated repo is a visit. This is also the only thing separating the pane's own agent from an agent it merely spawned — `SEAHELM_PANE_ID` (and the `ZMX_SESSION` the hook falls back to) is inherited by **every descendant process**, so a test harness that stands up its own agent in a generated app directory reports events under the pane's id with a cwd of its own. *Cooldown:* after any move, auto-follow holds off for 10 minutes (`autoRehomeCooldown`). An agent's cwd bounces while it works — Claude runs `cd <worktree> && …` for one tool call and is back at the repo root for the next — and following both directions walked the pane in and out, leaving a replacement pane behind on the source at every departure. The cooldown delays, it does not pin: once the agent has settled elsewhere the next event still moves the pane. The same-repo gate also sits on the pending-transfer path in `performPaneRehome`.

Hook-driven repo auto-add (`handleNewWorktreeFromHook`) has its own two guards for the same reason: `isEphemeralRepoPath` (tmp/caches) and `isToolStateRepoPath` (any repo root inside a hidden directory, e.g. `~/.amuxd/teams/<id>/apps/<id>`). Auto-add is silent and `workspacePaths` is never pruned, so without them every app a daemon generates becomes a permanent project. Explicit Add Repo is the user's call and consults neither.

Attribution is otherwise a continuous function of the agent's cwd, so an *undo* of an automatic move is not offered: it would only change seahelm's view, and the agent's next event would move the pane straight back. `seahelm pane move <pane> <worktree>` remains the manual path — it matters for panes that report no hooks at all, and it starts the same cooldown, so a manual correction stands rather than being reverted by the next event.

**Status detection pipeline:** `StatusPublisher` (background queue, 2s timer) → `readViewportText()` (with `ghosttyLock`) → `StatusDetector.detect()` → `DebouncedStatusTracker` → `WorktreeStatusAggregator` (main queue) → `AgentRegistry` → UI delegates. Preferred worktrees (active tab) poll every cycle; others every 3rd cycle.

**Auto-update:** Sparkle 2 (`Sources/Update/UpdateDriver.swift`, `Sources/App/UpdateCoordinator.swift`). `UpdateDriver` implements `SPUUserDriver` so updates render in the inline `UpdateBanner` instead of Sparkle's modals; it stashes each pending Sparkle reply block until the matching banner button is clicked. There is one appcast per CPU arch (we ship arch-specific zips and Sparkle has no arch filtering), so the feed URL is supplied at runtime by `UpdateCoordinator.feedURLString` rather than baked into Info.plist. `SUPublicEDKey` comes from the `SPARKLE_PUBLIC_ED_KEY` build setting; empty means Sparkle refuses to start. `scripts/package_release.sh` signs Sparkle's nested helpers (Autoupdate, Updater.app, `Downloader.xpc`, `Installer.xpc`) inside-out, then generates and signs `dist/appcast-<arch>.xml` from the final notarized zip using `SPARKLE_PRIVATE_KEY`.

**Focus management:** `GhosttyNSView` overrides `becomeFirstResponder`/`resignFirstResponder` to call `ghostty_surface_set_focus()` and apply visual shadow state. `mouseDown` calls `makeFirstResponder(self)`. Split pane operations defer `makeFirstResponder` via `DispatchQueue.main.async` to run after Ghostty's own deferred focus handling.

**Thread safety:** `ghosttyLock` (NSLock) serializes all Ghostty C API calls between the background status poll and main-thread input. Key input deliberately does NOT hold the lock (Ghostty is internally thread-safe for keys, and holding it would deadlock on synchronous callbacks).

**Window key handling:** `SeahelmWindow.performKeyEquivalent` handles split pane shortcuts (Cmd+D / Cmd+Shift+D split, Cmd+Option+Arrow move split focus, Cmd+Ctrl+Arrow resize) before menu key equivalents. `sendEvent` intercepts Escape.

## Agent Orchestration ("the fleet")

The structure is plain: one app ⊃ many **projects** (repos) ⊃ many **worktrees** ⊃ many **panes**, each pane running an **agent**. `AgentRegistry.shared` is the app-wide source of truth across all panes. (Note: `Station` is taken for the surface wrapper, so it names none of these tiers.)

This used to be a nautical metaphor — Ship / Deck / Cabin / Sailor for app / repo / worktree / pane — and older commits, branch names and issues still speak it. The rename dropped it because `Sailor` in particular had come to mean two things at once, the pane and the agent inside it, which is why the types below split along that line rather than mapping one-to-one onto the old names.

- **Pane / agent model** (`Sources/Core/`): `AgentType` = agent kind (claudeCode, codex, openCode, gemini, cline…), `AgentStatus` = state enum (owns the status-dot color), `PaneInfo` = per-pane snapshot, `PaneReducer` = pure `(old + inputs) → (new snapshot + delta)` (extracted from `AgentRegistry.updateStatus`), `AgentChannel` = protocol for talking to a pane's terminal (`ZmxChannel` is the universal fallback via the `zmx` CLI; `HooksChannel` is the richer path for agents that report structured events). Note `PaneStatus` is a different type: the per-pane snapshot the worktree rollup consumes, in `Sources/Status/`.

- **Manifest engine** (`Sources/Status/`): data-driven detection ported from a sibling project. `AgentManifest` is a JSON schema of priority-ordered regex rules/gates/process matchers (bundled under `Sources/Status/Manifests/`, overridable at `~/.config/seahelm/agents/<id>.json` — user override wins by id/alias). `ManifestStore` compiles them; `ManifestEngine` evaluates a terminal snapshot. The `*Decoder` files are the newer "signalman" seam: `SignalDecoder` translates one raw source into a unified `NormalizedEvent`; `ScanDecoder` wraps `StatusDetector` (screen-scan channel), `HookDecoder` maps webhook events. These feed the reducer/ingest pipeline broadcast through `EventHub`.

- **Control socket & CLI** (`Sources/Core/`): `ControlSocketServer` listens on a 0600 Unix socket at `~/.config/seahelm/seahelm.sock` speaking newline-delimited JSON-RPC (`ControlProtocol` = transport-free router + `ControlDataSource` seam; `SeahelmControlDataSource` bridges it to live app state). `SeahelmCliInstaller` writes `~/.local/bin/seahelm` (python3 wrapper) so agents run e.g. `seahelm pane run <id> npm test` — this backs the `seahelm` skill. The chat/Helm command language lives in `Sources/Core/Command/` (design: `docs/command-redesign.md`): `CommandSpecs` is the verb table every other piece is generated from, `CommandParser` is pure (text + `FleetIndex` → `CommandLine`), `CommandExecutor` is the one place a verb has meaning, and `CommandSession`/`CommandSessionStore` hold what each Telegram chat and mail thread is talking to — the desktop's session is the dashboard selection. Panes are addressed by a stable `#n` from `PaneHandleRegistry`, worktrees and repos by `@name`. `EventHub` is the fan-out broker (bounded ring buffer, `events_after` replay) for control-socket subscribers.

- **Hooks installers** (`Sources/Core/*HooksSetup.swift`, `*Installer.swift`): non-destructively install per-agent shims so third-party agent CLIs report lifecycle events back to seahelm. `SeahelmHookInstaller` writes `~/.local/bin/seahelm-hook` (the shared bridge: prefers the socket, falls back to HTTP webhook, relays Stop-hook block decisions via stdout); `ClaudeHooksSetup`/`CodexHooksSetup`/`CursorHooksSetup`/`OpenCodePluginInstaller` wire that bridge into each tool's config. `OnboardingHookInstaller` orchestrates which integrations get installed during the first-run wizard.

- **FirstMate** (`Sources/Core/FirstMate*.swift`): an autonomous supervisor reacting to agent status transitions. A green-zone/red-zone action model (watchWaiting, watchError, inspect, autoCommit, suggestNextOrder, broadcastOrder, integrationReport); `FirstMateConfig` holds user policy; `FirstMateCoordinator` (main thread) consumes status edges, routes green-zone actions to side effects and red-zone actions to the `PendingOrdersQueue`. Watches idle/blocked/errored agents and either auto-handles or surfaces them for approval.

- **Usage** (`Sources/Usage/`): `ClaudeUsageSummaryProvider`/`CodexUsageSummaryProvider` parse each tool's local session logs into token/quota figures; `UsageSummaryStore` refreshes both on a background timer and hands the snapshots to `IslandModel` — `UsageSummaryFormatter.readouts` turns them into `UsageReadout`s, which the closed pill rotates one window at a time (left wing, yielding to pending orders) and the opened header shows in full on the title row. Claude only reports rate limits inside its statusline payload, so `ClaudeStatuslineBridgeInstaller` (run at window setup) wraps the user's `statusLine` command to tee that payload into `~/Library/Caches/seahelm/claude-statusline.json`.

## Keyboard System (modal)

The modal Vim/which-key system described in `docs/keyboard-redesign.md` (NORMAL/INSERT `KeyboardMode`, `KeyboardModeController`, `Keymap`, `LeaderMenu`) is gone, and so is the last transient `KeyboardSubstate` — it only ever marked the inline create form, which went with the sidebar composer. `Sources/App/KeyboardMode.swift` now holds just `FocusDirection`. Whether bare keys navigate is decided by who owns focus (`RegionFocusController`); `GlobalKeymap` centralizes window-level Cmd shortcuts, and `SeahelmWindow.performKeyEquivalent` (below) still handles the split-pane Cmd shortcuts.

## Key Technical Details

- **Swift 5.10**, macOS 14.0+ (Sonoma), AppKit (not SwiftUI)
- **Ghostty C interop** via `seahelm-Bridging-Header.h` → `ghostty.h`; `GhosttyKit.xcframework` provides `libghostty`
- Links against: Metal, QuartzCore, IOSurface, Carbon, UniformTypeIdentifiers, libghostty, libc++
- SPM dependencies: `CodeEditSourceEditor` (+ `CodeEditLanguages`) for the embedded code editor; otherwise system frameworks + Ghostty
- Delegate pattern used throughout (not Combine/async-await for UI updates)
- `GhosttyBridge.shared` is the singleton entry point for all terminal operations
- `StationRegistry.shared` is the global surface lookup table (surface ID → Station)
- `AgentRegistry.shared` is the single source of truth for agent state (status, messages, activity events)
- Tests use XCTest with `@testable import seahelm`; test files in `Tests/` directory; no external test dependencies
- Config uses `decodeIfPresent()` throughout for backward compatibility with older config files
- `ghostty/` directory contains the vendored Ghostty source (read-only reference, not built from here)
