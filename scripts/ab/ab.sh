#!/bin/sh
# A/B stretch: the macOS app and the GPUI client used side by side, compared
# from their logs afterwards.
#
#   scripts/ab/ab.sh start     start the recorder and the shadow comparator
#   scripts/ab/ab.sh status
#   scripts/ab/ab.sh report [--hours N]
#   scripts/ab/ab.sh stop
#
# Data: $SEAHELM_AB_DIR (default ~/Library/Logs/seahelm-ab) for the recorder;
# the core, the GPUI client and the shadow comparator write under
# ~/.config/seahelm (core-events.jsonl, gpui-events.jsonl, core-shadow.jsonl).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
ab="${SEAHELM_AB_DIR:-$HOME/Library/Logs/seahelm-ab}"
core="${SEAHELM_CORE_BIN:-seahelm-core}"
mkdir -p "$ab"

alive() { [ -f "$ab/$1.pid" ] && kill -0 "$(cat "$ab/$1.pid")" 2>/dev/null; }

case "${1:-status}" in
start)
  alive recorder || { nohup python3 "$here/ab_record.py" >>"$ab/recorder.log" 2>&1 & echo $! >"$ab/recorder.pid"; }
  # Restarted whenever it exits: it gives up when the core goes away (a
  # core restart), and the comparison should outlive that.
  alive shadow || { nohup sh -c "while :; do '$core' shadow --follow-app; sleep 3; done" >>"$ab/shadow.log" 2>&1 & echo $! >"$ab/shadow.pid"; }
  [ -f "$ab/state.json" ] || printf '{"started_at": %s}\n' "$(date +%s)" >"$ab/state.json"
  "$0" status ;;
status)
  for p in recorder shadow; do
    if alive $p; then echo "$p: running (pid $(cat "$ab/$p.pid"))"; else echo "$p: stopped"; fi
  done
  [ -f "$ab/state.json" ] && echo "since: $(python3 -c "import json,time;print(time.ctime(json.load(open('$ab/state.json'))['started_at']))")" || true ;;
report)
  shift; python3 "$here/ab_report.py" "$@" ;;
stop)
  for p in recorder shadow; do
    if alive $p; then pid="$(cat "$ab/$p.pid")"; pkill -P "$pid" 2>/dev/null || true; kill "$pid" || true; fi
    rm -f "$ab/$p.pid"
  done
  "$0" status ;;
*) echo "usage: $0 start|status|report|stop" >&2; exit 2 ;;
esac
