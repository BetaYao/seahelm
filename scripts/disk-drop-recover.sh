#!/bin/bash
# disk-drop-recover.sh — Recover seahelm after the workspace volume dropped out.
#
# When the external volume holding the repo (and the zmx binary inside the app
# bundle) disappears, every zmx session daemon is wedged for good: its cwd and
# open fds point at a vnode that no longer exists. Remounting does not heal
# them — `zmx list` answers `err=Timeout status=unreachable` forever and seahelm
# cannot reattach. The only way out is to kill the daemons and relaunch the app,
# which re-issues each pane's `claude --resume <id>` from config.json.
#
# The daemons do NOT reliably burn CPU (they have been seen both spinning at
# ~55% and blocked at 0%), so CPU is not the tell. The tell is `unreachable`
# sessions plus every ~/.local/state/zmx/logs/*.log stopping at the same second.
#
# Usage: scripts/disk-drop-recover.sh [options]
#   --check         Diagnose only; change nothing.
#   --yes           Do not ask for confirmation.
#   --kill-strays   Also kill non-zmx processes left spinning on a dead cwd
#                   (Android emulator's netsimd, dev servers, …).
#   --no-launch     Kill and clean, but do not relaunch the app.
#   --volume PATH   Volume to check (default: the one holding this repo).
#   --detach        Re-exec detached, for running from inside a seahelm pane
#                   (the cleanup kills that pane's own shell otherwise).
#
# Exit codes: 0 = recovered, or nothing was wedged
#             10 = --check found wedged sessions
#             1 = failed
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_ONLY=0
ASSUME_YES=0
KILL_STRAYS=0
NO_LAUNCH=0
DETACH=0
DETACHED=0
VOLUME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --kill-strays) KILL_STRAYS=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    --detach) DETACH=1; shift ;;
    --detached) DETACHED=1; ASSUME_YES=1; shift ;;   # internal, set by --detach
    --volume) VOLUME="${2:?--volume needs a path}"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "disk-drop-recover: unknown option: $1" >&2; exit 1 ;;
  esac
done

say() { echo "==> $*"; }
warn() { echo "    ! $*" >&2; }

# `timeout(1)` is GNU coreutils and not on a stock macOS, but every call here
# talks to daemons that may be wedged — so a timeout is not optional.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  { sleep "$secs"; kill -9 "$pid" 2>/dev/null; } >/dev/null 2>&1 & local watcher=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  return "$rc"
}

# All zmx processes: the `run` session daemons and the `attach` clients. Matching
# on the subcommand keeps this from ever selecting the script itself. zmx is
# normally invoked by its full path inside the bundle, so accept a leading slash
# as well as a space (a bare `zmx run` typed by hand).
zmx_pids() { ps -axo pid=,command= | awk '$0 ~ /[ \/]zmx (run|attach)( |$)/ {print $1}'; }

seahelm_pids() { ps -axo pid=,command= | awk '$0 ~ /MacOS\/[S]eahelm( |$)/ {print $1}'; }

# ---------------------------------------------------------------- preflight

# Killing the zmx daemons takes down the pane this script runs in, so a run from
# inside seahelm never reaches the relaunch. Re-exec detached (nohup survives
# the pane's SIGHUP and launchd adopts it) or refuse.
if [ -n "${SEAHELM_PANE_ID:-}${ZMX_SESSION:-}" ] && [ "$DETACHED" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
  if [ "$DETACH" -eq 1 ]; then
    LOG="${TMPDIR:-/tmp/}seahelm-disk-drop-recover.log"
    args=(--detached)
    [ "$KILL_STRAYS" -eq 1 ] && args+=(--kill-strays)
    [ "$NO_LAUNCH" -eq 1 ] && args+=(--no-launch)
    [ -n "$VOLUME" ] && args+=(--volume "$VOLUME")
    say "Running inside a seahelm pane — re-executing detached."
    say "Follow along with: tail -f $LOG"
    nohup "$0" "${args[@]}" >"$LOG" 2>&1 &
    exit 0
  fi
  warn "This is a seahelm pane — the cleanup would kill this shell mid-run."
  warn "Run it from a standalone terminal, or pass --detach."
  exit 1
fi

if [ -z "$VOLUME" ]; then
  VOLUME="$(df -P "$ROOT" | awk 'NR==2 {print $NF}')"
fi

if [ ! -d "$VOLUME" ] || ! mount | grep -q " on $VOLUME "; then
  warn "$VOLUME is not mounted. Remount it first — the app bundle lives there."
  exit 1
fi

# Prefer the zmx inside the app bundle that is actually running: on a machine
# with several checkouts, the one on PATH may belong to a different build.
# $SEAHELM_ZMX overrides, for pointing at another bundle (or a test stub).
ZMX="${SEAHELM_ZMX:-}"
if [ -z "$ZMX" ]; then
  for pid in $(seahelm_pids); do
    app="$(ps -o command= -p "$pid" | sed -n 's|\(.*\.app\)/Contents/MacOS/.*|\1|p')"
    [ -n "$app" ] && [ -x "$app/Contents/Resources/bin/zmx" ] && ZMX="$app/Contents/Resources/bin/zmx" && break
  done
fi
[ -z "$ZMX" ] && [ -x "$ROOT/.build/Build/Products/Debug/Seahelm.app/Contents/Resources/bin/zmx" ] \
  && ZMX="$ROOT/.build/Build/Products/Debug/Seahelm.app/Contents/Resources/bin/zmx"
[ -z "$ZMX" ] && ZMX="$(command -v zmx || true)"
if [ -z "$ZMX" ]; then
  warn "No zmx binary found (looked in the running app, $ROOT/.build, and PATH)."
  exit 1
fi

# ---------------------------------------------------------------- diagnose

say "Volume:  $VOLUME"
say "zmx:     $ZMX"

LIST="$(with_timeout 30 "$ZMX" list 2>&1 || true)"
TOTAL="$(printf '%s\n' "$LIST" | grep -c 'name=' || true)"
UNREACHABLE="$(printf '%s\n' "$LIST" | grep -c 'status=unreachable' || true)"
say "Sessions: $TOTAL total, $UNREACHABLE unreachable"

# The fingerprint: several session logs stop at the same second AND that second
# is in the past. Sharing a timestamp proves nothing on its own — a healthy app
# writes every session in the same poll — so the age is what tells them apart.
# Only the newest timestamp is considered; retired sessions keep stale mtimes.
LOGDIR="$HOME/.local/state/zmx/logs"
if [ -d "$LOGDIR" ]; then
  EPOCHS="$(stat -f '%m' "$LOGDIR"/*.log 2>/dev/null || true)"
  NEWEST="$(printf '%s\n' "$EPOCHS" | sort -n | tail -1)"
  if [ -n "$NEWEST" ]; then
    SHARED="$(printf '%s\n' "$EPOCHS" | grep -c "^$NEWEST$" || true)"
    AGE=$(( $(date +%s) - NEWEST ))
    WHEN="$(date -r "$NEWEST" '+%Y-%m-%d %H:%M:%S')"
    if [ "$SHARED" -gt 1 ] && [ "$AGE" -gt 60 ]; then
      say "$SHARED session logs all stop at $WHEN, ${AGE}s ago — the disk-drop fingerprint."
    else
      say "Session logs current as of $WHEN (${AGE}s ago)"
    fi
  fi
fi

# Processes still running with a cwd that no longer resolves: same casualty
# class as the daemons (the emulator's netsimd, dev servers, build watchers).
STRAYS=""
while read -r pid cpu; do
  [ -z "$pid" ] && continue
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 || true)"
  case "$cwd" in
    *"No such file or directory"*) STRAYS="$STRAYS$pid $cpu $(ps -o comm= -p "$pid" 2>/dev/null | sed 's|.*/||')"$'\n' ;;
  esac
done < <(ps -axo pid=,%cpu= | awk '$2 > 5 {print $1, $2}')
STRAY_COUNT="$(printf '%s' "$STRAYS" | grep -c . || true)"
if [ "$STRAY_COUNT" -gt 0 ]; then
  say "Other processes spinning on a dead cwd ($STRAY_COUNT):"
  printf '%s' "$STRAYS" | awk '{printf "      pid=%-7s cpu=%-7s %s\n", $1, $2, $3}'
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  [ "$UNREACHABLE" -gt 0 ] && exit 10
  say "No wedged sessions."
  exit 0
fi

# Nothing wedged: seahelm is fine and must not be restarted for the sake of a
# stray. Clean the strays if asked, and leave the app alone either way.
if [ "$UNREACHABLE" -eq 0 ]; then
  say "No wedged sessions — seahelm does not need recovering."
  if [ "$STRAY_COUNT" -gt 0 ] && [ "$KILL_STRAYS" -eq 1 ]; then
    say "Killing $STRAY_COUNT dead-cwd process(es), leaving seahelm running…"
    printf '%s' "$STRAYS" | awk '{print $1}' | while read -r pid; do
      kill -9 "$pid" 2>/dev/null || true
    done
  elif [ "$STRAY_COUNT" -gt 0 ]; then
    say "(Pass --kill-strays to clean up the dead-cwd processes above.)"
  fi
  exit 0
fi

# ---------------------------------------------------------------- capture

# The safety net, taken before anything is killed: which agent session belongs
# to which pane. The app restores these from config.json on its own, but a
# corrupted or stale config is exactly the day this file earns its keep.
STAMP="$(date +%Y%m%d-%H%M%S)"
SAVE="$HOME/.local/state/seahelm/disk-drop-recovery/$STAMP"
mkdir -p "$SAVE"
cp "$HOME/.config/seahelm/config.json" "$SAVE/config.json" 2>/dev/null || warn "no config.json to back up"
printf '%s\n' "$LIST" > "$SAVE/zmx-list.txt"
ps -axo pid=,ppid=,stat=,%cpu=,etime=,command= > "$SAVE/ps.txt"

{
  echo "# captured $(date)"
  for c in $(pgrep -x claude || true); do
    cmd="$(ps -o command= -p "$c" 2>/dev/null || true)"
    rid="$(printf '%s' "$cmd" | sed -n 's/.*--resume \([0-9a-f-]*\).*/\1/p')"
    src="cmdline"
    meta="$HOME/.claude/sessions/$c.json"
    if [ -z "$rid" ] && [ -f "$meta" ]; then
      rid="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("sessionId") or d.get("session_id") or "")' "$meta" 2>/dev/null || true)"
      src="sessions.json"
    fi
    cwd="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("cwd") or "")' "$meta" 2>/dev/null || true)"
    echo "claude=$c resume=${rid:-NONE} src=$src cwd=$cwd"
  done
} > "$SAVE/agent-sessions.txt"
say "Captured resume ids and config to: $SAVE"

# ---------------------------------------------------------------- confirm

APP=""
for pid in $(seahelm_pids); do
  APP="$(ps -o command= -p "$pid" | sed -n 's|\(.*\.app\)/Contents/MacOS/.*|\1|p')"
  [ -n "$APP" ] && break
done
[ -z "$APP" ] && APP="$ROOT/.build/Build/Products/Debug/Seahelm.app"

ZMX_COUNT="$(zmx_pids | grep -c . || true)"
AGENTS="$(pgrep -x claude | grep -c . || true)"
echo
say "About to kill: seahelm app, $ZMX_COUNT zmx processes, $AGENTS agent process(es)."
say "Agents resume from config.json; in-flight tool runs (builds, tests) are lost."
[ "$NO_LAUNCH" -eq 0 ] && say "Then relaunch: $APP"

if [ "$ASSUME_YES" -eq 0 ]; then
  # Not -r: /dev/tty exists and looks readable even with no controlling
  # terminal, and only opening it says so ("Device not configured").
  if ! : 2>/dev/null < /dev/tty; then
    warn "Not running on a terminal — pass --yes to proceed unattended."
    say "Nothing was killed. Capture kept at $SAVE"
    exit 1
  fi
  printf "    Proceed? [y/N] "
  read -r reply < /dev/tty
  case "$reply" in [yY]*) ;; *) say "Aborted. Capture kept at $SAVE"; exit 0 ;; esac
fi

# ---------------------------------------------------------------- recover

say "Killing seahelm…"
pkill -f "MacOS/Seahelm" 2>/dev/null || true
sleep 2
for pid in $(seahelm_pids); do kill -9 "$pid" 2>/dev/null || true; done

say "Killing zmx daemons and clients…"
# SIGKILL, not `zmx kill`: a wedged daemon never answers, so the graceful path
# just burns its timeout. The claude processes inside exit on their own SIGHUP.
for pid in $(zmx_pids); do kill -9 "$pid" 2>/dev/null || true; done
sleep 1

SOCKET_DIR="${TMPDIR:-/tmp/}zmx-$(id -u)"
SOCKET_DIR="${SOCKET_DIR%//}"
if [ -d "$SOCKET_DIR" ]; then
  rm -f "$SOCKET_DIR"/* 2>/dev/null || true
  say "Cleared stale sockets in $SOCKET_DIR"
fi

if [ "$KILL_STRAYS" -eq 1 ] && [ "$STRAY_COUNT" -gt 0 ]; then
  say "Killing $STRAY_COUNT dead-cwd process(es)…"
  printf '%s' "$STRAYS" | awk '{print $1}' | while read -r pid; do
    kill -9 "$pid" 2>/dev/null || true
  done
fi

if [ "$NO_LAUNCH" -eq 1 ]; then
  say "Done (not relaunching). Capture: $SAVE"
  exit 0
fi

# `open`, never run.sh: a rebuild would compile whatever half-finished edits the
# agents left in the worktree, and the bundle on disk is known-good.
say "Relaunching $APP"
open "$APP"

# ---------------------------------------------------------------- verify

for _ in $(seq 1 12); do
  sleep 5
  [ -n "$(seahelm_pids)" ] && break
done
if [ -z "$(seahelm_pids)" ]; then
  warn "App did not come up. Capture kept at $SAVE"
  exit 1
fi

FINAL="$(with_timeout 30 "$ZMX" list 2>&1 || true)"
STILL="$(printf '%s\n' "$FINAL" | grep -c 'status=unreachable' || true)"
LIVE="$(printf '%s\n' "$FINAL" | grep -c 'name=' || true)"
if [ "$STILL" -gt 0 ]; then
  warn "$STILL session(s) still unreachable — run the script again."
  exit 1
fi

# Panes build their zmx session lazily, so a low count right after launch is
# normal: only the visible ones are up until you open the others.
say "Recovered. $LIVE session(s) up, none unreachable."
if [ -x "$HOME/.local/bin/seahelm" ]; then
  if with_timeout 20 "$HOME/.local/bin/seahelm" pane list >/dev/null 2>&1; then
    say "Control socket answers — the app is responsive."
  else
    warn "Control socket did not answer yet (it may still be starting)."
  fi
fi
say "Capture kept at $SAVE"
