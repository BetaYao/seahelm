# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Seahelm (sea + helm; AMUX — Agent Multiplexer) is a native macOS terminal multiplexer built with Swift + AppKit. It integrates the Ghostty terminal engine (via C bindings through GhosttyKit.xcframework) to render terminals, uses tmux for session persistence, and provides a dashboard UI for browsing git worktrees with agent status detection.

## Build Commands

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

# Run UI tests
xcodebuild -project seahelm.xcodeproj -scheme seahelmUITests -configuration Debug test

# Clean build
xcodebuild -project seahelm.xcodeproj -scheme seahelm clean
```

The project uses XcodeGen (`project.yml`) to generate the Xcode project file. After modifying `project.yml`, regenerate with `xcodegen generate`.

## Architecture

**Four-layer design:**

1. **App Coordinators** (`Sources/App/`)
   - `MainWindowController` — Window owner, embeds content VCs, positions traffic lights, handles keyboard shortcuts via `AmuxWindow` subclass
   - `TabCoordinator` — Orchestrates tab switching, repo VC lifecycle (cached in `repoVCs[repoPath]`), status update forwarding, and session state save/restore
   - `TerminalCoordinator` — Split pane operations (split, close, move focus, resize), worktree deletion, surface manager ownership
   - `PanelCoordinator` — Manages side panels (AI panel, notification panel)

2. **UI Layer** (`Sources/UI/`)
   - `Dashboard/` — Four layout modes: Grid, LeftRight, TopSmall, TopLarge. Grid uses frame-based layout; focus layouts use Auto Layout with a `FocusPanelView` + mini card sidebar
   - `Repo/` — `RepoViewController` with `SidebarViewController` for worktree switching; `SplitContainerView` hosts split panes
   - `Split/` — `SplitContainerView` renders `SplitTree` as frame-based leaf views with `DividerView` drag handles and dim overlays on unfocused panes
   - `TitleBar/` — Custom `TitleBarView` with project tabs, layout switcher, notification badge
   - `Dialog/` — Quick switcher (Cmd+P) and new branch dialog (Cmd+N)

3. **Core Services** (`Sources/Core/`, `Sources/Status/`)
   - `AgentHead` — Single source of truth for all agent state; delegates notify UI of changes
   - `StatusPublisher` — Timer-based polling (2s) on background queue, reads viewport text via `ghosttyLock`-protected C API calls
   - `StatusDetector` — Priority: process exit > OSC 133 shell phase > text pattern matching > Unknown
   - `WorktreeStatusAggregator` — Aggregates per-pane statuses into per-worktree status, fires `WorktreeStatusDelegate`
   - `Config` — JSON config at `~/.config/seahelm/config.json`; uses `decodeIfPresent()` for backward compat (migrated from legacy ~/.config/amux on first launch)
   - `SurfaceRegistry` — Global registry mapping surface IDs to `TerminalSurface` instances
   - `ExternalChannel` — Protocol for WeChat/WeCom bot integrations

4. **Terminal & System** (`Sources/Terminal/`, `Sources/Git/`)
   - `GhosttyBridge` — Singleton wrapping the Ghostty C API (`ghostty.h` via bridging header)
   - `TerminalSurface` — Wraps `GhosttyNSView` (NSView + Metal renderer + PTY); manages surface lifecycle, reparenting, and backend session attachment
   - `SplitTree` / `SplitNode` — Tree data structure for split pane layout; serializable for persistence in config
   - `WorktreeDiscovery` — Runs `git worktree list --porcelain` to discover worktrees

## Key Patterns

**Surface lifecycle:** TerminalSurface instances are long-lived — created once per split leaf, reparented between views (dashboard focus panel, repo tab split containers). `reparent(to:)` uses `CATransaction` to suppress animations, then defers size sync and focus restoration via two `DispatchQueue.main.async` passes. Surfaces are destroyed only on explicit deletion or app quit.

**Tab switching:** `detachActiveTerminal()` removes the active `SplitContainerView` from its superview before embedding the new tab's content. This prevents Z-order conflicts when surfaces are shared across views.

**Split pane system:** `SplitTree` is a binary tree of `SplitNode` (leaf or split with axis + ratio). `SplitContainerView.layoutTree()` computes frame-based positions for each leaf, places `GhosttyNSView` instances, adds `DividerView` drag handles, and updates dim overlays. Focus is tracked via `tree.focusedId`; `GhosttyNSView.onFocusAcquired` callback keeps the tree in sync when user clicks a pane.

**Terminal persistence:** Backend sessions (tmux or zmx) named `amux-<parent>-<name>` are created per split leaf. For zmx, a health check runs 3s after creation; stale sessions trigger `recoverZmxSession` (destroy + recreate). Split layouts are serialized to config for restore on relaunch.

**Status detection pipeline:** `StatusPublisher` (background queue, 2s timer) → `readViewportText()` (with `ghosttyLock`) → `StatusDetector.detect()` → `DebouncedStatusTracker` → `WorktreeStatusAggregator` (main queue) → `AgentHead` → UI delegates. Preferred worktrees (active tab) poll every cycle; others every 3rd cycle.

**Focus management:** `GhosttyNSView` overrides `becomeFirstResponder`/`resignFirstResponder` to call `ghostty_surface_set_focus()` and apply visual shadow state. `mouseDown` calls `makeFirstResponder(self)`. Split pane operations defer `makeFirstResponder` via `DispatchQueue.main.async` to run after Ghostty's own deferred focus handling.

**Thread safety:** `ghosttyLock` (NSLock) serializes all Ghostty C API calls between the background status poll and main-thread input. Key input deliberately does NOT hold the lock (Ghostty is internally thread-safe for keys, and holding it would deadlock on synchronous callbacks).

**Window key handling:** `AmuxWindow.performKeyEquivalent` handles split pane shortcuts (Cmd+D split, Cmd+Shift+Arrow move focus, Cmd+Ctrl+Arrow resize) before menu key equivalents. `sendEvent` intercepts Escape.

## Key Technical Details

- **Swift 5.10**, macOS 14.0+ (Sonoma), AppKit (not SwiftUI)
- **Ghostty C interop** via `seahelm-Bridging-Header.h` → `ghostty.h`; `GhosttyKit.xcframework` provides `libghostty`
- Links against: Metal, QuartzCore, IOSurface, Carbon, UniformTypeIdentifiers, libghostty, libc++
- SPM dependencies: `CodeEditSourceEditor` (+ `CodeEditLanguages`) for the embedded code editor; otherwise system frameworks + Ghostty
- Delegate pattern used throughout (not Combine/async-await for UI updates)
- `GhosttyBridge.shared` is the singleton entry point for all terminal operations
- `SurfaceRegistry.shared` is the global surface lookup table (surface ID → TerminalSurface)
- `AgentHead.shared` is the single source of truth for agent state (status, messages, activity events)
- Tests use XCTest with `@testable import seahelm`; test files in `Tests/` directory; no external test dependencies
- Config uses `decodeIfPresent()` throughout for backward compatibility with older config files
- `ghostty/` directory contains the vendored Ghostty source (read-only reference, not built from here)
