#!/bin/bash
# Long-run performance monitor for Seahelm (see issue #35).
#
# Sampling is driven by a launchd agent rather than a foreground loop, so the
# run survives closing the pane it was started from, app restarts, and
# sleep/wake. The job removes itself once the deadline passes.
set -uo pipefail

LABEL="com.seahelm.perfmon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PERF_DIR="${SEAHELM_PERF_DIR:-$HOME/Library/Logs/seahelm-perf}"
SAMPLES="$PERF_DIR/samples.jsonl"
STATE="$PERF_DIR/state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLER="$SCRIPT_DIR/seahelm_perf_sample.py"
REPORTER="$SCRIPT_DIR/seahelm_perf_report.py"
# Apple's python3 by preference: a `brew upgrade` mid-run must not be able to
# move the interpreter out from under a 48h launchd job.
PYTHON="$([[ -x /usr/bin/python3 ]] && echo /usr/bin/python3 || command -v python3)"
DOMAIN="gui/$(id -u)"

usage() {
  cat <<'EOF'
Usage: perfmon.sh <command> [options]

  start [--hours N] [--interval S]   start a monitored run (default 48h, 60s)
  stop                               stop early
  status                             job state, deadline, latest sample
  report [--hours H] [--last N] [--json]
  raw [N]                            last N raw JSONL rows (default 5)

Data lives in ~/Library/Logs/seahelm-perf (override with SEAHELM_PERF_DIR).
EOF
}

cmd_start() {
  local hours=48 interval=60
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hours) hours="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
  done

  mkdir -p "$PERF_DIR" "$PERF_DIR/diagnostics" "$PERF_DIR/bin"
  chmod +x "$SAMPLER" "$REPORTER" 2>/dev/null

  # Run from a snapshot under ~/Library rather than from the checkout: a launchd
  # agent has no TCC grant for external volumes (the repo lives on /Volumes), and
  # a long run should keep the sampler it started with even if the repo copy is
  # edited mid-flight.
  cp "$SAMPLER" "$PERF_DIR/bin/seahelm_perf_sample.py"
  cp "$REPORTER" "$PERF_DIR/bin/seahelm_perf_report.py"
  chmod +x "$PERF_DIR/bin/"*.py
  local run_sampler="$PERF_DIR/bin/seahelm_perf_sample.py"

  # Archive any previous run so a fresh window starts clean.
  if [[ -s "$SAMPLES" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    mv "$SAMPLES" "$PERF_DIR/samples-$stamp.jsonl"
    echo "==> archived previous run to samples-$stamp.jsonl"
  fi

  local now deadline
  now="$(date +%s)"
  deadline="$(echo "$now + $hours * 3600" | bc)"
  "$PYTHON" - "$STATE" "$interval" "$deadline" "$now" <<'PY'
import json, sys
path, interval, deadline, started = sys.argv[1], int(sys.argv[2]), int(float(sys.argv[3])), int(sys.argv[4])
json.dump({"interval_s": interval, "deadline_epoch": deadline, "started_epoch": started},
          open(path, "w"), indent=2)
PY

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON</string>
    <string>$run_sampler</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>SEAHELM_PERF_DIR</key><string>$PERF_DIR</string></dict>
  <key>StartInterval</key><integer>$interval</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>5</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$PERF_DIR/monitor.log</string>
  <key>StandardErrorPath</key><string>$PERF_DIR/monitor.log</string>
</dict>
</plist>
EOF

  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  launchctl bootstrap "$DOMAIN" "$PLIST" || { echo "failed to bootstrap $LABEL" >&2; exit 1; }
  launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1

  echo "==> monitoring every ${interval}s for ${hours}h (until $(date -r "$deadline" '+%Y-%m-%d %H:%M'))"
  echo "    samples: $SAMPLES"
  echo "    report:  $SCRIPT_DIR/perfmon.sh report"
}

cmd_stop() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
  if [[ -f "$STATE" ]]; then
    "$PYTHON" - "$STATE" <<'PY'
import json, sys, time
path = sys.argv[1]
try:
    state = json.load(open(path))
except Exception:
    state = {}
state["stopped_epoch"] = int(time.time())
state["stopped_reason"] = "manual stop"
json.dump(state, open(path, "w"), indent=2)
PY
  fi
  echo "==> stopped $LABEL"
}

cmd_status() {
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "job:      loaded"
  else
    echo "job:      not loaded"
  fi
  [[ -f "$STATE" ]] && "$PYTHON" - "$STATE" "$SAMPLES" <<'PY'
import json, os, sys, time
state = json.load(open(sys.argv[1]))
now = time.time()
def stamp(value):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(value)) if value else "-"
print("started:  %s" % stamp(state.get("started_epoch")))
print("deadline: %s (%.1fh left)" % (stamp(state.get("deadline_epoch")),
                                     max(0, (state.get("deadline_epoch", now) - now) / 3600.0)))
if state.get("stopped_epoch"):
    print("stopped:  %s (%s)" % (stamp(state["stopped_epoch"]), state.get("stopped_reason")))
print("samples:  %s (last %s)" % (state.get("samples", 0), stamp(state.get("last_sample_epoch"))))
path = sys.argv[2]
if os.path.exists(path):
    last = None
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if line:
                last = line
    if last:
        row = json.loads(last)
        app, mem, probe = row.get("app", {}), row.get("mem", {}), row.get("probe", {})
        print("latest:   footprint %sMB  cpu %s%%  main_block %sms  panes %s  threads %s" % (
            mem.get("footprint_mb"), app.get("cpu_pct_interval", app.get("cpu_pct_ps")),
            probe.get("main_block_ms"), (row.get("panes") or {}).get("total"), app.get("threads")))
PY
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  report) shift; "$PYTHON" "$REPORTER" "$@" ;;
  raw) tail -n "${2:-5}" "$SAMPLES" ;;
  -h|--help|"") usage ;;
  *) echo "unknown command: $1" >&2; usage >&2; exit 2 ;;
esac
