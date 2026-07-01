# Bundle zmx into seahelm (eliminate install friction)

**Date:** 2026-07-01
**Status:** Approved design — pending implementation plan

## Problem

seahelm depends on the external `zmx` binary for terminal session persistence.
Users must install it separately (`brew install neurosnap/tap/zmx`), and when it
is missing the app degrades to `tmux`/`local` and shows an install-nag dialog.
The dependency is **deep in wiring but thin in substance** — the only feature
that genuinely matters is `zmx attach` (PTY persistence). `zmx run` and
`zmx history` are already secondary paths (input is typed into the ghostty
surface directly; status is read via `readViewportText()`).

**Sole motivation:** remove install friction so seahelm works out of the box
with nothing to install.

## Non-goals (YAGNI)

- **No** in-house terminal daemon or client binary, no PTY code.
- **No** `TerminalBackend` protocol abstraction — not until a second real
  backend exists.
- **No** change to `tmux` or `local` backend behavior.
- **No** change to `zmx run` / `zmx history` semantics.

## What zmx is (bundling viability)

- 1.6 MB single Mach-O binary; only dynamic dependency is
  `/usr/lib/libSystem.B.dylib` (always present on macOS). No external dylibs.
- **MIT licensed** → free to bundle and redistribute (must ship the license).
- Public: `github.com/neurosnap/zmx`.

## zmx usage surface (what the seam must cover)

| Invocation | Site | Purpose |
|---|---|---|
| `zmx attach <s>` | `Station` (ghostty child `command`) | PTY persistence — the core value |
| `zmx run <s> <cmd>` | `ZmxChannel.sendCommand` | out-of-band command inject (secondary) |
| `zmx history <s>` | `ZmxChannel.readOutput` | out-of-band scrollback read (secondary) |
| `zmx list` | `SessionManager`, `Station.forceKill…` | enumerate live sessions |
| `zmx kill <s>` | `SessionManager.killSession` | terminate a session |
| `zmx version` | `BackendResolver`, `Station` (socket dir) | version gate / find socket dir |

All CLI calls run via `ProcessRunner` → `/usr/bin/env zmx …` (PATH-resolved).
The ghostty child command is the string `"zmx attach <s>"`, resolved on the
child process's `PATH`. `ProcessRunner.commandExists("zmx")` drives both backend
fallback and the install-nag dialog.

## Design

### 1. The seam: `ZmxLocator`

One type owns "where is the zmx binary," so no site hardcodes `"zmx"`.

```swift
enum ZmxLocator {
    /// Absolute path to the zmx binary. Bundled copy always wins; PATH is only
    /// consulted when no bundled binary exists (dev builds without the fetch step).
    static func path() -> String?          // nil only if neither bundled nor on PATH
    static var isBundled: Bool { get }
}
```

Resolution order (**bundled always wins**):
1. `Bundle.main.resourceURL/bin/zmx` if it exists and is executable → return it.
2. Otherwise search `PATH` (dev fallback) → return first hit.
3. Otherwise `nil`.

Call-site changes:
- `ProcessRunner` zmx calls: `["zmx", …]` → `[ZmxLocator.path()!, …]` (guarded).
- Ghostty child command: `"zmx attach \(s)"` →
  `"\(ShellEscape.quote(ZmxLocator.path()!)) attach \(s)"` (reuse existing
  `ShellEscape`; the Resources path may contain spaces).
- `commandExists("zmx")` → `ZmxLocator.path() != nil`.

This is also the future-daemon seam: the one place that knows *which* executable
provides persistence. Command strings stay at their existing call sites (they
just swap the executable token for `ZmxLocator.path()`); we do **not** introduce
a command-builder type or a `TerminalBackend` protocol until a second real
backend exists.

### 2. Bundling & build

- **Fetch-with-checksum build phase** (not committed to git):
  - A script downloads the **pinned** zmx release for **arm64** (Apple Silicon
    only — the sole supported target) from GitHub releases, verifies it against a
    committed SHA-256, and places it at `Contents/Resources/bin/zmx`. No `lipo` /
    universal step.
  - The pinned version + checksums live in a committed file
    (e.g. `Vendor/zmx.pin`); upgrades are a deliberate edit.
  - The script is **idempotent/cached**: if the destination already matches the
    pinned checksum, skip the download (offline incremental builds work once
    fetched).
- **Re-sign** the binary with the app identity under hardened runtime
  (`codesign --force --options runtime --sign <identity>`), so notarization
  passes. Runs as a build phase after the copy.
- Ship `Resources/licenses/zmx-LICENSE` (MIT text).

### 3. Runtime resolution & fallback

- `ZmxLocator.path()` returns the bundled binary in shipped builds; falls back to
  `PATH` only in dev builds that skipped the fetch.
- **Delete the install-friction UX**: the "zmx is not installed / brew install …"
  branch in `BackendResolver.showWarningIfNeeded` and the corresponding
  `warningMessage` become unreachable (bundled zmx is always available). The
  version gate is retained but evaluates the bundled version (always supported),
  so it is effectively a no-op safety net.
- `resolvePreferredBackend` still supports `tmux`/`local` for users who
  explicitly choose them; `zmx` is now always available as a backend.

### 4. Error handling

- If `ZmxLocator.path()` is `nil` (should only happen in a broken dev build):
  fall back to `tmux` if present, else `local`, exactly as today. No dialog.
- Build-script failures (download error, checksum mismatch) **fail the build**
  loudly — a mismatch must never ship silently.

### 5. Testing

- `ZmxLocator` resolution via injected filesystem/PATH lookups (pure):
  bundled-present → returns bundled; bundled-absent + on PATH → returns PATH;
  neither → `nil`.
- Command-builder strings (`attach`/`run`/`history`/`kill`/`list`) verified,
  including `ShellEscape` quoting of a path containing spaces.
- Existing `BackendResolver` tests updated: the "not installed" cases now reflect
  bundled-always-available; version-gate tests retained.

## Rollout / impact

- No user-facing behavior change except: no install step, no nag dialog,
  deterministic zmx version across all installs.
- App bundle grows ~1.6 MB (arm64 zmx).
- First build after this change requires network to fetch zmx; subsequent builds
  are cached.
