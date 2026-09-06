# Seahelm

A native macOS workspace for coding agents, git worktrees, and parallel development.

[中文文档](README.zh-CN.md) · [www.seahelm.dev](https://www.seahelm.dev/)

## Demo

![Seahelm demo](assets/tour.gif)

Full walkthrough: [YouTube](https://youtu.be/WUUcuglx_Ks)

## Why Seahelm

Several tools now run coding agents side by side on macOS. Seahelm shares the obvious
parts with them — Swift, libghostty, one git worktree per agent, hooks for status.
Three things are its own.

**It lives outside the terminal.** A multiplexer puts status inside the window you
are trying to stop watching. Seahelm's Island sits at the edge of the screen and
stays quiet until a worktree needs you, blocked agents raise real system
notifications, and you can answer one from your phone over iMessage. Claude and
Codex token and quota usage are summarised in-app, so you also see when an agent is
about to run out of budget rather than out of ideas.

**Built around the decision, not the display.** Seahelm intercepts the Stop hook and
makes the agent hand back its next-step options before it is allowed to stop. Those
arrive as clickable cards. First Mate watches status transitions and either handles
them or queues them for your approval. Showing "awaiting input" is the easy half; the
question is what to do about it.

**The pane follows its agent.** When an agent creates a worktree and starts working
there, that pane moves to the new worktree's card instead of an empty pane appearing
beside it. Keyed on the cwd every hook payload carries, with a same-repo gate and a
cooldown so a `cd x && ...` tool call doesn't walk the pane back and forth.

Beyond that: native rendering on the Ghostty engine rather than Electron, sessions
that survive a reboot via zmx, and status detection for 12 agents out of the box.

## How It Was Built

Seahelm is vibe-coded. Nearly every line was written by coding agents — Claude Code and
Codex — directed at the level of what should happen, not reviewed diff by diff. It was
also built inside itself: the worktrees, split panes and status detection described below
were written by agents running in Seahelm's own worktrees, split panes and status
detection.

Worth knowing before you install it:

- The code is public and MIT so you can read it instead of taking its word for anything.
- Roughly 1,900 unit tests cover the behaviour that could be specified up front. The paths
  that could not are where the bugs are.
- A bug report with a reproduction is the single most useful thing you can send. It is
  what turns a rough edge into a fix.

## Install

```bash
curl -fsSL https://seahelm.dev/install.sh | sh
```

Or download from [GitHub Releases](https://github.com/BetaYao/seahelm/releases/latest).

## Screenshots

### Workspace

![Workspace](assets/screenshots/workspace.png)

### File browser & code editor

![File browser and code editor](assets/screenshots/code-editor.png)

### Tab layout

![Tab layout](assets/screenshots/tab-layout.png)

## Features

**Workspace & panes** — Manage multiple repos and git worktrees as tabs. Split panes inside a worktree so multiple agents run in parallel.

**Agent status** — Manifest-driven status detection covers 12 agents: agent, aider, amp, claude, cline, codex, cursor, gemini, goose, kiro, opencode, pi. Claude Code and Codex have native hook integration with suggestion cards.

| Agent | Status detection | Event hooks | Suggestion cards |
|---|---|---|---|
| Claude Code | ✅ | ✅ native hooks | ✅ |
| Codex | ✅ | ✅ native hooks | ✅ |
| opencode | ✅ | ✅ plugin | ⚠️ model-volunteered |
| Others (9) | ✅ screen-scan | — | — |

**Side panel** — File tree, code editor (CodeEditSourceEditor), Markdown preview, and git diff review without leaving the worktree.

**The Island** — A status pill at the top of the screen. Stays quiet until a worktree needs you: running, waiting, or broken. Agent suggestions arrive as clickable cards.

**First Mate** — Watches pane state transitions and generates cards: suggestions, waiting/error alerts, and "return to port" cleanup prompts.

**Control socket** — Agents can drive Seahelm via a CLI:

```bash
seahelm pane list
seahelm pane read <pane> --lines 50
seahelm pane split <pane> --direction right
seahelm pane run <pane> "npm test"
seahelm wait agent-status <pane> --status Idle
seahelm pane explain <pane>       # which rule decided this status?
seahelm layout export
```

Every pane gets `SEAHELM_PANE_ID` for self-reference. Full surface: `seahelm <ping|session|pane|wait|events|layout>`.

**Token usage** — Claude and Codex token/quota usage summarized in-app.

**Sessions** — Persisted by [zmx](https://zmx.sh). Quit the app or reboot, and the agent is still where you left it. Falls back to plain processes when zmx is unavailable.

## Who It's For

- Developers working with Claude Code, Codex, or similar coding agents
- People managing multiple branches and worktrees daily
- Teams using AI-assisted coding in regular development

## Local Development

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
```

Build (`CodeEditSourceEditor` requires skipping plugin validation):

```bash
xcodebuild -project seahelm.xcodeproj -scheme seahelm \
  -configuration Debug -skipPackagePluginValidation -skipMacroValidation build
```

Build and launch (artifacts in `.build/`):

```bash
./run.sh
```

Run UI tests:

```bash
./run_ui_tests.sh
```

Package a release zip for the current architecture:

```bash
./scripts/package_release.sh   # → dist/
```

## Architecture

Swift + AppKit, macOS 14.0+, four layers:

- **App coordinators** (`Sources/App/`) — window, tabs, split panes, side panels
- **UI layer** (`Sources/UI/`) — dashboard, island, splits, title bar, worktree sidebar
- **Core services** (`Sources/Core/`, `Sources/Status/`) — agent state tracking, status detection pipeline, First Mate rules engine, control socket
- **Terminal & system** (`Sources/Terminal/`, `Sources/Git/`) — Ghostty C API, git worktree discovery

See [`CLAUDE.md`](CLAUDE.md) for details and [`docs/`](docs/) for design notes.

## Releases

Pushing a `v*` tag triggers the release workflow, which builds `arm64` and `x86_64` macOS artifacts.

With repository secrets configured (`APPLE_CERTIFICATE_P12`, `APPLE_DEVELOPER_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, etc.), the workflow also signs, notarizes, and staples the app.

## License

Seahelm is released under the [MIT License](LICENSE).

It builds on other people's work — notably the [Ghostty](https://github.com/ghostty-org/ghostty)
terminal engine (MIT) and [zmx](https://zmx.sh) for session persistence. Bundled Swift packages
are MIT, BSD-3-Clause, or Apache-2.0; each retains its own copyright and license.

Third-party components bundled in the app — Ghostty, zmx, Sparkle and the Swift
packages — are listed with their full license texts in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
