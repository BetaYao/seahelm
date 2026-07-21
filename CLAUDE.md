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
   - `Dashboard/` — Four layout modes: Grid, LeftRight, TopSmall, TopLarge. Grid uses frame-based layout; focus layouts use Auto Layout with a `FocusPanelView` + mini card sidebar
   - `Repo/` — `RepoViewController` with `SidebarViewController` for worktree switching; `SplitContainerView` hosts split panes
   - `Split/` — `SplitContainerView` renders `SplitTree` as frame-based leaf views with `DividerView` drag handles and dim overlays on unfocused panes
   - `Chrome/` — Two-column `WindowChromeController` (sidebar/terminal headers, divider, collapse)
   - `Dialog/` — Quick switcher (Cmd+P) and new branch dialog (Cmd+N)
   - `SidePanel/` — Per-worktree right panel with First Mate / Files / Changes tabs (`WorktreeSidePanelViewController`, `BridgePanelViewController` for red/green-zone orders)
   - `Diff/` — Code-review diff viewer (`DiffReviewView` + `DiffSyntaxHighlighter`)
   - `Helm/` — The command-line "helm" input (`CommandInputView` with `/command · @repo · #agent` autocomplete) + keyboard-help overlay
   - `StatusBar/` — Fixed 26pt bottom bar: mode indicator, global Claude/Codex usage, notification summary, shortcuts
   - `Island/` — Floating "dynamic island" panel (morphs closed pill ↔ open surface) for notifications/status
   - `Settings/`, `Onboarding/` — Tabbed settings window and the first-run wizard

3. **Core Services** (`Sources/Core/`, `Sources/Status/`)
   - `ShipLog` — Single source of truth for all agent state; delegates notify UI of changes
   - `StatusPublisher` — Timer-based polling (2s) on background queue, reads viewport text via `ghosttyLock`-protected C API calls
   - `StatusDetector` — Authoritative status detector. Priority: process exit > OSC 133 shell phase > text pattern matching > Unknown. Its text-pattern tier consults a `CompiledManifest` from the manifest engine (see below); the manifest layer augments, it does not replace, this ladder.
   - `WorktreeStatusAggregator` — Aggregates per-pane statuses into per-worktree status, fires `WorktreeStatusDelegate`
   - `Config` — JSON config at `~/.config/seahelm/config.json`; uses `decodeIfPresent()` for backward compat (migrated from legacy ~/.config/amux on first launch)
   - `StationRegistry` — Global registry mapping surface IDs to `Station` instances
   - `ExternalChannel` — Protocol for inbound remote-control chat (`WeChatChannel`, `WeComBotChannel`)

4. **Terminal & System** (`Sources/Terminal/`, `Sources/Git/`)
   - `GhosttyBridge` — Singleton wrapping the Ghostty C API (`ghostty.h` via bridging header)
   - `Station` — Wraps `GhosttyNSView` (NSView + Metal renderer + PTY); manages surface lifecycle, reparenting, and backend session attachment
   - `SplitTree` / `SplitNode` — Tree data structure for split pane layout; serializable for persistence in config
   - `WorktreeDiscovery` — Runs `git worktree list --porcelain` to discover worktrees

## Key Patterns

**Surface lifecycle:** Station instances are long-lived — created once per split leaf, reparented between views (dashboard focus panel, repo tab split containers). `reparent(to:)` uses `CATransaction` to suppress animations, then defers size sync and focus restoration via two `DispatchQueue.main.async` passes. Surfaces are destroyed only on explicit deletion or app quit.

**Tab switching:** `detachActiveTerminal()` removes the active `SplitContainerView` from its superview before embedding the new tab's content. This prevents Z-order conflicts when surfaces are shared across views.

**Split pane system:** `SplitTree` is a binary tree of `SplitNode` (leaf or split with axis + ratio). `SplitContainerView.layoutTree()` computes frame-based positions for each leaf, places `GhosttyNSView` instances, adds `DividerView` drag handles, and updates dim overlays. Focus is tracked via `tree.focusedId`; `GhosttyNSView.onFocusAcquired` callback keeps the tree in sync when user clicks a pane.

**Terminal persistence:** `runtimeBackend` is `"zmx"` (default) or `"local"` — there is no user-facing backend choice and no tmux backend. `MainWindowController` starts optimistically at `"zmx"` so early tree restore attaches persistent sessions before the async availability check lands, then falls back to `"local"` if zmx is missing. `local` panes are plain processes with no persistence (`SessionManager` guards `backend == "zmx"`). zmx sessions are named `seahelm-<parent>-<name>` (`.` and `:` replaced with `_`, truncated past `maxSessionNameLength`) and created per split leaf; a health check runs 3s after creation (`Station.recoveryDelay`) and stale sessions trigger `recoverZmxSession` (destroy + recreate). Split layouts are serialized to config for restore on relaunch.

**Status detection pipeline:** `StatusPublisher` (background queue, 2s timer) → `readViewportText()` (with `ghosttyLock`) → `StatusDetector.detect()` → `DebouncedStatusTracker` → `WorktreeStatusAggregator` (main queue) → `ShipLog` → UI delegates. Preferred worktrees (active tab) poll every cycle; others every 3rd cycle.

**Auto-update:** Sparkle 2 (`Sources/Update/UpdateDriver.swift`, `Sources/App/UpdateCoordinator.swift`). `UpdateDriver` implements `SPUUserDriver` so updates render in the inline `UpdateBanner` instead of Sparkle's modals; it stashes each pending Sparkle reply block until the matching banner button is clicked. There is one appcast per CPU arch (we ship arch-specific zips and Sparkle has no arch filtering), so the feed URL is supplied at runtime by `UpdateCoordinator.feedURLString` rather than baked into Info.plist. `SUPublicEDKey` comes from the `SPARKLE_PUBLIC_ED_KEY` build setting; empty means Sparkle refuses to start. `scripts/package_release.sh` signs Sparkle's nested helpers (Autoupdate, Updater.app, `Downloader.xpc`, `Installer.xpc`) inside-out, then generates and signs `dist/appcast-<arch>.xml` from the final notarized zip using `SPARKLE_PRIVATE_KEY`.

**Focus management:** `GhosttyNSView` overrides `becomeFirstResponder`/`resignFirstResponder` to call `ghostty_surface_set_focus()` and apply visual shadow state. `mouseDown` calls `makeFirstResponder(self)`. Split pane operations defer `makeFirstResponder` via `DispatchQueue.main.async` to run after Ghostty's own deferred focus handling.

**Thread safety:** `ghosttyLock` (NSLock) serializes all Ghostty C API calls between the background status poll and main-thread input. Key input deliberately does NOT hold the lock (Ghostty is internally thread-safe for keys, and holding it would deadlock on synchronous callbacks).

**Window key handling:** `SeahelmWindow.performKeyEquivalent` handles split pane shortcuts (Cmd+D split, Cmd+Shift+Arrow move focus, Cmd+Ctrl+Arrow resize) before menu key equivalents. `sendEvent` intercepts Escape.

## Agent Orchestration ("the fleet")

Seahelm frames the whole app with a nautical metaphor worth knowing before reading this code. You (the app / user) are the **Captain** of one **Ship**, and the structural hierarchy nests physically:

| Concept | Term | Relationship |
|---------|------|--------------|
| the app / user | **Ship** (Captain) | top level, singular |
| repo | **Deck** | a Ship has many Decks |
| worktree | **Cabin** | a Deck has many Cabins |
| pane / agent | **Sailor** | a Cabin has many Sailors doing the work |

So: one Ship ⊃ many Decks (repos) ⊃ many Cabins (worktrees) ⊃ many Sailors (panes/agents). `ShipLog.shared` is the Ship-wide source of truth across all Sailors. (Note: `Station` is already taken for the surface wrapper, so it is deliberately not used for any tier above.)

- **Sailor model** (`Sources/Core/Sailor*.swift`): `SailorType` = agent kind (claudeCode, codex, openCode, gemini, cline…), `SailorStatus` = state enum (owns the status-dot color), `SailorInfo` = per-pane snapshot, `SailorReducer` = pure `(old + inputs) → (new snapshot + delta)` (extracted from `ShipLog.updateStatus`), `SailorChannel` = protocol for talking to a sailor's terminal (`ZmxChannel` is the universal fallback via the `zmx` CLI; `HooksChannel` is the richer path for agents that report structured events).

- **Manifest engine** (`Sources/Status/`): data-driven detection ported from a sibling project. `AgentManifest` is a JSON schema of priority-ordered regex rules/gates/process matchers (bundled under `Sources/Status/Manifests/`, overridable at `~/.config/seahelm/agents/<id>.json` — user override wins by id/alias). `ManifestStore` compiles them; `ManifestEngine` evaluates a terminal snapshot. The `*Decoder` files are the newer "signalman" seam: `SignalDecoder` translates one raw source into a unified `NormalizedEvent`; `ScanDecoder` wraps `StatusDetector` (screen-scan channel), `HookDecoder` maps webhook events. These feed the reducer/ingest pipeline broadcast through `EventHub`.

- **Control socket & CLI** (`Sources/Core/`): `ControlSocketServer` listens on a 0600 Unix socket at `~/.config/seahelm/seahelm.sock` speaking newline-delimited JSON-RPC (`ControlProtocol` = transport-free router + `ControlDataSource` seam; `SeahelmControlDataSource` bridges it to live app state). `SeahelmCliInstaller` writes `~/.local/bin/seahelm` (python3 wrapper) so agents run e.g. `seahelm pane run <id> npm test` — this backs the `seahelm` skill. `BridgeCommand`/`BridgeCommandRouter` are a separate higher-level command grammar used by the chat/bridge surfaces (worktrees, orders, "return to port"). `EventHub` is the fan-out broker (bounded ring buffer, `events_after` replay) for control-socket subscribers.

- **Hooks installers** (`Sources/Core/*HooksSetup.swift`, `*Installer.swift`): non-destructively install per-agent shims so third-party agent CLIs report lifecycle events back to seahelm. `SeahelmHookInstaller` writes `~/.local/bin/seahelm-hook` (the shared bridge: prefers the socket, falls back to HTTP webhook, relays Stop-hook block decisions via stdout); `ClaudeHooksSetup`/`CodexHooksSetup`/`CursorHooksSetup`/`OpenCodePluginInstaller` wire that bridge into each tool's config. `OnboardingHookInstaller` orchestrates which integrations get installed during the first-run wizard.

- **FirstMate** (`Sources/Core/FirstMate*.swift`): an autonomous supervisor reacting to agent status transitions. A green-zone/red-zone action model (watchWaiting, watchError, inspect, autoCommit, suggestNextOrder, returnToPort, broadcastOrder); `FirstMateConfig` holds user policy; `FirstMateCoordinator` (main thread) consumes status edges, routes green-zone actions to side effects and red-zone actions to the `PendingOrdersQueue`. Watches idle/blocked/errored agents and either auto-handles or surfaces them for approval.

- **Usage** (`Sources/Usage/`): `ClaudeUsageSummaryProvider`/`CodexUsageSummaryProvider` parse each tool's local session logs into token/quota figures; `UsageSummaryStore` refreshes both on a background timer and emits the global usage readout shown in the status bar.

## Keyboard System (modal)

`Sources/App/` has a modal Vim/which-key-style keyboard system (design in `docs/keyboard-redesign.md`). `KeyboardMode` = NORMAL vs INSERT (+ transient `KeyboardSubstate`); `KeyboardModeController` owns the mode machine and the leader (`Space`) which-key descent. `Keymap` resolves bare-key NORMAL chords to `KeyboardAction` (h/j/k/l focus, i=insert, d=delete, c=changes); `GlobalKeymap` centralizes window-level Cmd shortcuts; `DialogKeymap` unifies modal-dialog nav; `LeaderMenu` holds `LeaderCommand` leaf actions reachable through the leader tree (kept separate from `KeyboardAction`). Note `SeahelmWindow.performKeyEquivalent` (below) still handles the split-pane Cmd shortcuts.

## Key Technical Details

- **Swift 5.10**, macOS 14.0+ (Sonoma), AppKit (not SwiftUI)
- **Ghostty C interop** via `seahelm-Bridging-Header.h` → `ghostty.h`; `GhosttyKit.xcframework` provides `libghostty`
- Links against: Metal, QuartzCore, IOSurface, Carbon, UniformTypeIdentifiers, libghostty, libc++
- SPM dependencies: `CodeEditSourceEditor` (+ `CodeEditLanguages`) for the embedded code editor; otherwise system frameworks + Ghostty
- Delegate pattern used throughout (not Combine/async-await for UI updates)
- `GhosttyBridge.shared` is the singleton entry point for all terminal operations
- `StationRegistry.shared` is the global surface lookup table (surface ID → Station)
- `ShipLog.shared` is the single source of truth for agent state (status, messages, activity events)
- Tests use XCTest with `@testable import seahelm`; test files in `Tests/` directory; no external test dependencies
- Config uses `decodeIfPresent()` throughout for backward compatibility with older config files
- `ghostty/` directory contains the vendored Ghostty source (read-only reference, not built from here)
