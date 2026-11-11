# seahelm-gpui (prototype)

A seahelm client drawn with [GPUI](https://gpui.rs), aimed at Windows and
Linux and built and tested on macOS first. It does not run the terminal
through a second PTY the way the AppKit app does (Ghostty running
`seahelmd attach`). It connects to seahelmd's socket directly, parses the
session's output with libghostty-vt (`keep-vt`) on a thread of its own, and
draws the grid from libghostty-vt's render state, reading only the rows that
changed.

The window copies the macOS app's dashboard (`MACOS-SPEC.md` holds the
measurements taken from the Swift sources and the live window): the fleet
column on the left, the selected worktree's terminal on the right.

## Run

```sh
export KEEP_GHOSTTY_VT_DIR=~/.cache/seahelm/libghostty-vt/vt-<version>-aarch64-macos
(cd ../../seahelmd && cargo build --release -p seahelmd)
cargo build --release

# The whole window. Projects are the client's own (folder button), their
# worktrees come from git, statuses from seahelm-core (started if needed).
SEAHELMD_DIR=/tmp/sgd SEAHELMD_BIN=<path to seahelmd> seahelm-gpui

# One bare terminal on one session, for measuring.
SEAHELM_GPUI_STATS=1 seahelm-gpui --session NAME [-- CMD...]
```

Set `SEAHELMD_DIR` to keep the prototype's sessions apart from the app's.
Each worktree gets a session of its own, named `gpui-<worktree>-<hash>`.
They are not the app's live sessions, because seahelmd sizes a session to
its smallest viewer and attaching to the app's sessions would shrink its
panes.

### Windows and Linux

What differs is in `src/platform.rs`: sessions and seahelm-core are reached
over seahelmd's own transport (named pipes on Windows, the pipe names
`seahelm-core` uses), the home directory is `%USERPROFILE%` when there is no
`HOME`, the terminal face defaults to the bundled JetBrains Mono, and the
app's shortcuts are ctrl+shift (paste is ctrl+shift+v) because ctrl belongs
to the terminal. On Windows the window has no caption: the header is the
drag area and draws minimise / maximise / close itself. On Linux the window
manager decorates it. Windows CI builds and tests the client; the fleet
column is still read from the macOS app, so off macOS it stays empty until
the fleet comes from seahelm-core. Memory per session is read from `ps`, so
it shows only on Unix.

`SEAHELM_GPUI_STATS=1` prints, once a second: frames drawn, average and worst
frame time, rows read from the grid, input MB/s, and how many whole-screen
repaints the daemon has sent.

## Measured (M-series Mac, release build)

`time seq 1 3000000` in a session (about 21 MB of output):

| path | before pump coalescing | after |
|---|---|---|
| no client attached (PTY + daemon parse) | 2.0 s | 2.0 s |
| `seahelmd attach` behind another PTY (what the AppKit app does) | 10.9 s | 2.5 s |
| seahelm-gpui | 5.4 s | 2.55 s |

Frame time while that runs, with the whole screen redrawn every frame:
0.6–1.3 ms on average and about 2.5 ms at worst.

"Pump coalescing" is the change in `seahelmd/crates/seahelmd/src/daemon.rs`.
The daemon used to send one frame per PTY read (about 1 KiB on macOS), so a
chatty program filled the 64-chunk client backlog and the client was repaid
with whole-screen repaints, hundreds per second. Each frame now carries
everything already queued, up to 256 KiB.

## What works

- Scrollback (wheel, overlay thumb), mouse selection (drag, double-click
  word, triple-click line, alt for a rectangle, autoscroll), copy (cmd+c /
  ctrl+shift+c), paste.
- Input methods: composition drawn at the cursor, candidates placed there.
- Splits per worktree, each pane its own seahelmd session: cmd+d /
  cmd+shift+d / cmd+w / cmd+alt+arrows on macOS; ctrl+shift+e / o / w and
  ctrl+alt+arrows elsewhere; the header's split button. Dividers drag (ratio
  0.1–0.9) and double-click back to even; unfocused panes are washed. The
  layout is kept in `~/.config/seahelm/gpui-layout.json`.
- No macOS app behind it. Projects are the client's own list
  (`gpui-projects.json`, folder button), worktrees come from `git worktree
  list`, statuses from seahelm-core, and agents' hooks reach the core
  directly (`seahelm-core install-hooks`, run when the core is started).
  The font is set in `gpui.json` (`font_family`, `font_size`).
- The group button cycles repository / status / activity grouping.
- Dark and light (Catppuccin Mocha / Latte): starts as the system is; the
  contrast button flips the chrome and every pane live, and programs that
  asked (DEC 2031) are told.
- The macOS app checks for signed GPUI releases through Sparkle and offers the
  update for install. It follows `auto_update.enabled` and
  `auto_update.check_interval_hours` in `~/.config/seahelm/config.json`.

## Not done yet

- Light theme fills (sidebar, rows, hairlines) are worked out from the
  light semantic colours, not measured off the app as the dark ones were.
- The side panels (Files, Changes), edit mode, sharing, PR badges, First
  Mate and the per-group buttons are the macOS app's and are not here.
- Diff stats are measured against the merge-base with the default branch.
  The app counts "what still has to go in a PR" (merged-PR heads,
  `git merge-tree`), so the numbers can differ.
- Icons are approximations of the SF Symbols from [Lucide](https://lucide.dev) (ISC; each SVG keeps its license header), since SF Symbols may only be drawn on Apple platforms. Window chrome is opaque,
  with the sidebar colour measured off the live app instead of vibrancy.
  Under GPUI's blurred background, translucent fills at 10% or less barely
  showed. Inactive traffic lights draw black because the window does not
  take the dark appearance.
