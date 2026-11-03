# seahelmd

seahelm's session daemon: one process per pane session owns the PTY, keeps the
screen in libghostty-vt, and repaints it exactly for whoever attaches — so the
app can quit, crash or update while the agents keep working. Bundled in the app
as `Contents/Resources/bin/seahelmd`; it replaced zmx, whose verbs it keeps.

- `crates/keep-vt` — safe bindings for libghostty-vt, taken whole from
  [ttwwnn/keep](https://github.com/ttwwnn/keep) (MIT, see `LICENSE-keep`).
- `crates/seahelmd` — the daemon and its zmx-shaped CLI. `session.rs` is
  adapted from keep's `keepd/src/tab.rs`.

```sh
../scripts/build-seahelmd.sh /tmp/seahelmd   # what the app build runs; caches libghostty-vt
cargo test                                    # needs vendor/libghostty-vt, or KEEP_GHOSTTY_VT_DIR:
KEEP_GHOSTTY_VT_DIR=~/.cache/seahelm/libghostty-vt/a53771af0165-aarch64-macos cargo test
```

| command | |
|---|---|
| `run <name> [cmd…]` | type `cmd` + Enter into the session's shell, creating the session on `$SHELL` first (zmx's `run`) |
| `new [--hold SECS] <name> [--] cmd…` | a session whose program is `cmd`; held, it starts on the first attach (at that size) or when the hold runs out |
| `attach <name> [cmd…]` | attach, creating the session first if needed |
| `list` | one line per session: `name= pid= clients= cwd= cmd=` |
| `send <name> <text>` | write bytes to the session's input |
| `history <name>` | screen and scrollback as plain text |
| `kill <name>` | end the session |

What it does that zmx did not:

- **One daemon per session**, as zmx — a crash takes one pane, not all of them.
- **Questions are answered while nobody is attached.** `SEAHELMD_FACTS`
  (`fg=cdd6f4 bg=1e1e2e cursor=f5e0dc dark=1`) is what OSC 10/11/12 and the
  colour-scheme query get back from a session with no client, so an agent
  started detached reads the real palette instead of caching "no colours".
- **A slow client is repainted, not queued forever** (keep's resync).
