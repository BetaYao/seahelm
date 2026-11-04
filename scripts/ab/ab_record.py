#!/usr/bin/env python3
"""Recorder for an A/B stretch: the macOS app and the GPUI client side by side.

Writes into $SEAHELM_AB_DIR (default ~/Library/Logs/seahelm-ab):
  app-events.jsonl  the app's own decisions, from its events.subscribe
                    (read only: nothing is sent to the app but the subscribe)
  samples.jsonl     every 30 s: CPU and memory of the app, the GPUI client,
                    seahelm-core and the seahelmd daemons (app's vs GPUI's)

The core writes its decisions itself (~/.config/seahelm/core-events.jsonl),
the GPUI client its own (gpui-events.jsonl), and `seahelm-core shadow
--follow-app` the app/core disagreements (core-shadow.jsonl); ab.sh starts
that beside this.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

AB = os.environ.get("SEAHELM_AB_DIR", os.path.expanduser("~/Library/Logs/seahelm-ab"))
APP_SOCK = os.environ.get("SEAHELM_SOCKET_PATH", os.path.expanduser("~/.config/seahelm/seahelm.sock"))
SAMPLE_EVERY = 30


def append(name, record):
    record["recorded_at"] = time.time()
    with open(os.path.join(AB, name), "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def follow_app():
    pause = 1
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(APP_SOCK)
            req = {"jsonrpc": "2.0", "id": 1, "method": "events.subscribe",
                   "params": {"types": ["pane.status_changed", "pane.closed", "pane.unseen_changed", "pane.rehomed"]}}
            s.sendall((json.dumps(req) + "\n").encode())
            s.settimeout(120)
            pause = 1
            buf = b""
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    # Notifications arrive as {"method": ..., "params": event} or bare.
                    ev = ev.get("params", ev) if isinstance(ev, dict) else ev
                    if isinstance(ev, dict) and str(ev.get("type", "")).startswith("pane."):
                        append("app-events.jsonl", ev)
        except OSError:
            pass
        time.sleep(pause)
        pause = min(pause * 2, 30)


def classify(args):
    exe = args.split(" ", 1)[0]
    base = os.path.basename(exe)
    if exe.endswith("/Contents/MacOS/Seahelm"):
        return "app"
    if base == "seahelm-gpui":
        return "gpui"
    if base == "seahelm-core" and " serve" in args:
        return "core"
    if base == "seahelmd":
        return "seahelmd-gpui" if " gpui-" in args else "seahelmd-app"
    return None


def sample():
    while True:
        try:
            out = subprocess.run(["ps", "-axo", "pid=,%cpu=,rss=,args="], capture_output=True, text=True, timeout=20).stdout
            groups = {}
            for line in out.splitlines():
                parts = line.split(None, 3)
                if len(parts) < 4:
                    continue
                pid, cpu, rss, args = parts
                g = classify(args)
                if not g:
                    continue
                e = groups.setdefault(g, {"procs": 0, "cpu": 0.0, "rss_mb": 0.0})
                e["procs"] += 1
                e["cpu"] += float(cpu)
                e["rss_mb"] += int(rss) / 1024
            append("samples.jsonl", {"groups": groups})
        except Exception as e:  # keep sampling whatever one round does
            print(f"sample: {e}", file=sys.stderr)
        time.sleep(SAMPLE_EVERY)


def main():
    os.makedirs(AB, exist_ok=True)
    threading.Thread(target=follow_app, daemon=True).start()
    sample()


if __name__ == "__main__":
    main()
