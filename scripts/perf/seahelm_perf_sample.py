#!/usr/bin/env python3
"""One sampling pass of Seahelm's runtime health, appended as a JSONL row.

Driven by launchd (see perfmon.sh) rather than an internal loop, so the run
survives terminal closes, app restarts and sleep/wake cycles.

Three families of signal, chosen to separate the failure modes seen in #35:

  * main-thread latency — `layout.export` hops to the main thread via
    DispatchQueue.main.sync, `ping` stays on the socket queue. The difference is
    how long the main thread made a caller wait, i.e. the "卡死" metric.
  * memory — the app's own phys_footprint/compressed (via app.memory) plus the
    machine's swap and swapout counters, so app growth and system thrash can be
    told apart.
  * render telemetry — the DEBUG `[DashboardOverview]` counters, read back out
    of the unified log, so full vs incremental renders are attributable.

Nothing here writes to the app; the probes are read-only.
"""

import json
import os
import re
import socket
import subprocess
import sys
import time
from datetime import datetime

PERF_DIR = os.environ.get("SEAHELM_PERF_DIR") or os.path.expanduser("~/Library/Logs/seahelm-perf")
SAMPLES_PATH = os.path.join(PERF_DIR, "samples.jsonl")
STATE_PATH = os.path.join(PERF_DIR, "state.json")
DIAG_DIR = os.path.join(PERF_DIR, "diagnostics")
SOCKET_PATH = os.environ.get("SEAHELM_SOCKET_PATH") or os.path.expanduser("~/.config/seahelm/seahelm.sock")
LAUNCHD_LABEL = "com.seahelm.perfmon"

PROBE_TIMEOUT_S = 20.0
# A deep capture is expensive (`sample` alone costs ~6s of CPU), so it is both
# threshold-gated and rate-limited.
CAPTURE_COOLDOWN_S = 900
MAIN_BLOCK_CAPTURE_MS = 1500
CPU_CAPTURE_PCT = 150
FOOTPRINT_CAPTURE_MB = 2000
CPU_CAPTURE_STREAK = 3


def run(cmd, timeout=15):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout
    except Exception:
        return ""


# ---------------------------------------------------------------- process


def app_pid():
    """The process answering our probes.

    More than one Seahelm can be alive at once — the `.build` app, an Xcode
    DerivedData build, an XCTest host — and only one of them owns the control
    socket. Resolving by socket owner keeps the ps metrics describing the same
    process as `app.memory` and `pane.list`; `pgrep` ordering does not.
    """
    out = run(["lsof", "-t", SOCKET_PATH], timeout=15).strip()
    if out:
        return int(out.split()[0])
    for name in ("Seahelm", "seahelm"):
        out = run(["pgrep", "-x", name], timeout=5).strip()
        if out:
            # Prefer the .build bundle: that is what run.sh launches.
            pids = [int(p) for p in out.split()]
            for pid in pids:
                if "/.build/" in run(["ps", "-o", "command=", "-p", str(pid)], timeout=5):
                    return pid
            return pids[0]
    return None


def binary_path(pid):
    return run(["ps", "-o", "command=", "-p", str(pid)], timeout=5).strip().split()[0] if pid else None


def _seconds(value):
    """Parse ps durations: [[dd-]hh:]mm:ss[.ss]."""
    days = 0
    if "-" in value:
        head, value = value.split("-", 1)
        days = int(head)
    parts = [float(p) for p in value.split(":")]
    total = 0.0
    for part in parts:
        total = total * 60 + part
    return total + days * 86400


def process_metrics(pid):
    out = run(["ps", "-o", "etime=,rss=,%cpu=,time=", "-p", str(pid)], timeout=10).strip()
    if not out:
        return None
    etime, rss_kb, pcpu, cputime = out.split()
    return {
        "pid": pid,
        "up_s": round(_seconds(etime), 1),
        "rss_mb": round(int(rss_kb) / 1024.0, 1),
        # ps %cpu is a decaying average over roughly the last minute, which
        # matches the default cadence. cpu_s is cumulative — the report
        # differences it for an exact per-interval figure.
        "cpu_pct_ps": float(pcpu),
        "cpu_s": round(_seconds(cputime), 2),
        "threads": thread_count(pid),
    }


def thread_count(pid):
    out = run(["top", "-l", "1", "-pid", str(pid), "-stats", "pid,th"], timeout=20)
    match = re.search(r"^\s*%d\s+(\d+)" % pid, out, re.MULTILINE)
    return int(match.group(1)) if match else None


def zmx_metrics():
    out = run(["ps", "-axo", "pid=,rss=,comm="], timeout=15)
    procs, rss_kb = 0, 0
    for line in out.splitlines():
        if "zmx" not in line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        procs += 1
        rss_kb += int(parts[1])
    return {"procs": procs, "rss_mb": round(rss_kb / 1024.0, 1)}


def _top_mem_mb(value):
    """Parse top's MEM column ("4240K", "720M", "12G") into MB."""
    match = re.match(r"^([\d.]+)([BKMGT]?)\+?$", value.strip())
    if not match:
        return None
    scale = {"": 1 / 1048576.0, "B": 1 / 1048576.0, "K": 1 / 1024.0,
             "M": 1.0, "G": 1024.0, "T": 1048576.0}[match.group(2)]
    return round(float(match.group(1)) * scale, 1)


def fseventsd_metrics():
    """fseventsd's real memory, which `ps` RSS does not reveal.

    This daemon sits idle while holding an enormous dirty working set, so nearly
    all of its pages end up compressed or swapped out and RSS only counts what is
    still resident. On 2026-08-16, after 49 days up, `ps` reported 7-8MB (swinging
    to 921MB and back between samples) while `top` reported 12G for the same pid —
    on a 16GB machine. Killing it released 8.1GB of swap. RSS is what made it look
    like a 720MB nuisance twice; top's MEM column is the number that counts the
    compressed pages, so that is the one sampled here.

    `pid` is recorded because launchd restarts fseventsd immediately on kill, and
    a restart resets the floor — the report has to segment on it rather than read
    the drop as a reclaim.
    """
    pid_out = run(["pgrep", "-x", "fseventsd"], timeout=10).strip()
    if not pid_out:
        return {"running": False}
    pid = int(pid_out.split()[0])
    row = {"running": True, "pid": pid}

    top_out = run(["top", "-l", "1", "-pid", str(pid), "-stats", "pid,mem"], timeout=20)
    match = re.search(r"^\s*%d\s+(\S+)" % pid, top_out, re.MULTILINE)
    row["mem_mb"] = _top_mem_mb(match.group(1)) if match else None

    ps_out = run(["ps", "-o", "etime=,rss=,%cpu=", "-p", str(pid)], timeout=10).strip()
    if ps_out:
        etime, rss_kb, pcpu = ps_out.split()
        row["up_s"] = round(_seconds(etime), 1)
        # Kept alongside mem_mb precisely so the gap between them stays visible.
        row["rss_mb"] = round(int(rss_kb) / 1024.0, 1)
        row["cpu_pct_ps"] = float(pcpu)
    return row


# ---------------------------------------------------------------- socket probes


def call(method, params=None, timeout=PROBE_TIMEOUT_S):
    """Returns (result_or_None, elapsed_ms, error_or_None)."""
    start = time.monotonic()
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(SOCKET_PATH)
        payload = json.dumps({"id": "perfmon", "method": method, "params": params or {}}) + "\n"
        sock.sendall(payload.encode())
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
        sock.close()
        elapsed = (time.monotonic() - start) * 1000
        obj = json.loads(buf.split(b"\n", 1)[0])
        if "error" in obj:
            return None, elapsed, obj["error"].get("message", "error")
        return obj.get("result", {}), elapsed, None
    except Exception as exc:
        return None, (time.monotonic() - start) * 1000, "%s: %s" % (type(exc).__name__, exc)


def probe():
    _, ping_ms, ping_err = call("ping")
    # layout.export is read-only but runs inside runOnMain, so its round trip
    # includes however long the main thread stayed busy.
    _, main_ms, main_err = call("layout.export")
    memory, mem_ms, _ = call("app.memory")
    panes, panes_ms, _ = call("pane.list")

    result = {
        "probe": {
            "ping_ms": round(ping_ms, 1),
            "main_ms": round(main_ms, 1),
            "main_block_ms": round(max(0.0, main_ms - ping_ms), 1),
            "memory_ms": round(mem_ms, 1),
            "panelist_ms": round(panes_ms, 1),
            "error": ping_err or main_err,
        }
    }

    if memory:
        result["mem"] = {
            "footprint_mb": round(memory.get("phys_footprint_mb", 0), 1),
            "resident_mb": round(memory.get("resident", 0) / 1048576.0, 1),
            "compressed_mb": round(memory.get("compressed", 0) / 1048576.0, 1),
            "peak_mb": round(memory.get("resident_peak", 0) / 1048576.0, 1),
            "panes_total": memory.get("panes_total"),
            "panes_awake": memory.get("panes_awake"),
            "panes_asleep": memory.get("panes_asleep"),
            "mb_per_awake_pane": round(memory.get("mb_per_awake_pane", 0), 1),
        }

    if panes is not None:
        rows = panes.get("panes", [])
        by_status = {}
        for row in rows:
            key = (row.get("status") or "Unknown").lower()
            by_status[key] = by_status.get(key, 0) + 1
        result["panes"] = {
            "total": len(rows),
            "running": by_status.get("running", 0),
            "by_status": by_status,
            "worktrees": len({r.get("worktree_path") for r in rows if r.get("worktree_path")}),
            "projects": len({r.get("project") for r in rows if r.get("project")}),
        }
    return result


# ---------------------------------------------------------------- system


def system_metrics():
    page_size = 16384
    stats = {}
    vm = run(["vm_stat"], timeout=10)
    match = re.search(r"page size of (\d+) bytes", vm)
    if match:
        page_size = int(match.group(1))
    for line in vm.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        value = value.strip().rstrip(".")
        if value.isdigit():
            stats[key.strip()] = int(value)

    def mb(key):
        return round(stats.get(key, 0) * page_size / 1048576.0, 1)

    swap = run(["sysctl", "-n", "vm.swapusage"], timeout=10)
    used = re.search(r"used\s*=\s*([\d.]+)M", swap)
    total = re.search(r"total\s*=\s*([\d.]+)M", swap)

    return {
        "free_mb": mb("Pages free") + mb("Pages speculative"),
        "compressor_mb": mb("Pages occupied by compressor"),
        "wired_mb": mb("Pages wired down"),
        # Cumulative counters; the report differences them into a rate, which is
        # the honest way to see thrash starting.
        "swapins": stats.get("Swapins", 0),
        "swapouts": stats.get("Swapouts", 0),
        "swap_used_mb": float(used.group(1)) if used else None,
        "swap_total_mb": float(total.group(1)) if total else None,
    }


# ---------------------------------------------------------------- render telemetry

TELEMETRY_RE = re.compile(
    r"\[DashboardOverview\] rows=(\d+) full_count=(\d+) full_avg_ms=([\d.]+) "
    r"incremental_count=(\d+) incremental_avg_ms=([\d.]+)"
)


def _render_window(window_s, pid):
    # Scoped to the live app's pid on purpose: the XCTest host is also called
    # "Seahelm", and each test builds a fresh DashboardOverviewView whose first
    # render logs — a test run would otherwise masquerade as app render churn.
    out = run(
        [
            "/usr/bin/log",
            "show",
            "--last",
            "%ds" % int(window_s),
            "--style",
            "compact",
            "--predicate",
            'processIdentifier == %d AND eventMessage CONTAINS "[DashboardOverview]"' % pid,
        ],
        timeout=60,
    )
    return TELEMETRY_RE.findall(out)


def render_metrics(window_s, pid, fallback_s=900):
    """Last DEBUG render telemetry line the app emitted inside the window.

    The app only logs when the overview actually renders, and at most once per
    30s, so a quiet interval yields nothing — fall back to a wider window so the
    cumulative counters stay available (flagged stale, since they then predate
    this sample). Counters live on the view instance and reset when it is
    rebuilt; the report treats a negative delta as a reset, not as progress.
    """
    stale = False
    matches = _render_window(window_s, pid)
    if not matches:
        matches = _render_window(fallback_s, pid)
        stale = True
    if not matches:
        return None
    rows, full, full_avg, incr, incr_avg = matches[-1]
    return {
        "rows": int(rows),
        "full_count": int(full),
        "full_avg_ms": float(full_avg),
        "incr_count": int(incr),
        "incr_avg_ms": float(incr_avg),
        "log_lines": len(matches),
        "window_s": int(fallback_s if stale else window_s),
        "stale": stale,
    }


# ---------------------------------------------------------------- state / capture


def load_state():
    try:
        with open(STATE_PATH) as handle:
            return json.load(handle)
    except Exception:
        return {}


def save_state(state):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(state, handle, indent=2)
    os.replace(tmp, STATE_PATH)


def deep_capture(pid, reasons, state, now):
    if not pid or not reasons:
        return None
    last = state.get("last_capture_epoch", 0)
    if now - last < CAPTURE_COOLDOWN_S:
        return None
    os.makedirs(DIAG_DIR, exist_ok=True)
    stamp = datetime.fromtimestamp(now).strftime("%Y%m%d-%H%M%S")
    sample_path = os.path.join(DIAG_DIR, "sample-%s.txt" % stamp)
    vmmap_path = os.path.join(DIAG_DIR, "vmmap-%s.txt" % stamp)
    run(["sample", str(pid), "3", "-file", sample_path], timeout=120)
    with open(vmmap_path, "w") as handle:
        handle.write(run(["vmmap", "-summary", str(pid)], timeout=120))
    with open(os.path.join(DIAG_DIR, "index.txt"), "a") as handle:
        handle.write("%s\t%s\t%s\n" % (stamp, ",".join(reasons), os.path.basename(sample_path)))
    state["last_capture_epoch"] = now
    return {"reasons": reasons, "sample": os.path.basename(sample_path), "vmmap": os.path.basename(vmmap_path)}


def stop_launchd_job():
    run(["launchctl", "bootout", "gui/%d/%s" % (os.getuid(), LAUNCHD_LABEL)], timeout=20)


# ---------------------------------------------------------------- main


def sample_once():
    """One pass. Returns True when the run has reached its deadline."""
    os.makedirs(PERF_DIR, exist_ok=True)
    now = time.time()
    state = load_state()
    interval = state.get("interval_s", 60)

    row = {
        "ts": datetime.fromtimestamp(now).isoformat(timespec="seconds"),
        "epoch": int(now),
    }

    pid = app_pid()
    if pid is None:
        row["app_down"] = True
    else:
        metrics = process_metrics(pid)
        if metrics is None:
            row["app_down"] = True
        else:
            metrics["binary"] = binary_path(pid)
            row["app"] = metrics
            row.update(probe())
            row["render"] = render_metrics(interval + 20, pid)

    row["zmx"] = zmx_metrics()
    row["fsevents"] = fseventsd_metrics()
    row["sys"] = system_metrics()

    reasons = []
    app = row.get("app") or {}
    prob = row.get("probe") or {}
    mem = row.get("mem") or {}
    if prob.get("error"):
        reasons.append("probe_error")
    if (prob.get("main_block_ms") or 0) > MAIN_BLOCK_CAPTURE_MS:
        reasons.append("main_block")
    if (mem.get("footprint_mb") or 0) > FOOTPRINT_CAPTURE_MB:
        reasons.append("footprint")

    prev_cpu_s = state.get("prev_cpu_s")
    prev_pid = state.get("prev_pid")
    prev_epoch = state.get("prev_epoch")
    cpu_pct = None
    if app and prev_cpu_s is not None and prev_pid == app["pid"] and prev_epoch:
        span = now - prev_epoch
        if span > 0:
            cpu_pct = round((app["cpu_s"] - prev_cpu_s) / span * 100, 1)
            row["app"]["cpu_pct_interval"] = cpu_pct
    streak = state.get("cpu_streak", 0)
    streak = streak + 1 if (cpu_pct or 0) > CPU_CAPTURE_PCT else 0
    state["cpu_streak"] = streak
    if streak >= CPU_CAPTURE_STREAK:
        reasons.append("cpu_sustained")

    capture = deep_capture(app.get("pid"), reasons, state, now)
    if capture:
        row["capture"] = capture
    if reasons:
        row["flags"] = reasons

    with open(SAMPLES_PATH, "a") as handle:
        handle.write(json.dumps(row) + "\n")

    if app:
        state["prev_cpu_s"] = app["cpu_s"]
        state["prev_pid"] = app["pid"]
    state["prev_epoch"] = now
    state["last_sample_epoch"] = now
    state["samples"] = state.get("samples", 0) + 1

    deadline = state.get("deadline_epoch")
    if deadline and now >= deadline:
        state["stopped_epoch"] = now
        state["stopped_reason"] = "deadline reached"
        save_state(state)
        with open(SAMPLES_PATH, "a") as handle:
            handle.write(json.dumps({"ts": row["ts"], "epoch": int(now), "event": "monitor_stopped"}) + "\n")
        stop_launchd_job()
        return True
    save_state(state)
    return False


def loop(interval):
    """Sample on a drift-corrected schedule until the deadline.

    launchd's StartInterval turned out to be advisory: on a machine deep in swap
    it coalesced 60s ticks into 3-minute ones. Owning the clock here keeps the
    cadence honest and skips a python start-up per sample.
    """
    started = time.monotonic()
    tick = 0
    while True:
        try:
            if sample_once():
                return 0
        except Exception as exc:  # one bad pass must not end a 48h run
            sys.stderr.write("sample failed: %s: %s\n" % (type(exc).__name__, exc))
            sys.stderr.flush()
        tick += 1
        target = started + tick * interval
        # After a system sleep the target may be far in the past; skip the
        # missed ticks rather than firing a burst to catch up.
        while target < time.monotonic():
            tick += 1
            target = started + tick * interval
        time.sleep(max(0.0, target - time.monotonic()))


def main():
    if "--loop" in sys.argv:
        index = sys.argv.index("--loop")
        interval = float(sys.argv[index + 1]) if len(sys.argv) > index + 1 else 60.0
        return loop(interval)
    sample_once()
    return 0


if __name__ == "__main__":
    sys.exit(main())
