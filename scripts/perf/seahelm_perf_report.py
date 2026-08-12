#!/usr/bin/env python3
"""Summarise a Seahelm perf-monitor run.

Reads the JSONL written by seahelm_perf_sample.py and answers the four
questions #35 raises: is the main thread stalling, is memory growing without
bound, are renders still going full-rebuild, and is the machine thrashing.

Usage:
  seahelm_perf_report.py [--last N] [--hours H] [--json]
"""

import argparse
import json
import os
import sys
from datetime import datetime

PERF_DIR = os.environ.get("SEAHELM_PERF_DIR") or os.path.expanduser("~/Library/Logs/seahelm-perf")
SAMPLES_PATH = os.path.join(PERF_DIR, "samples.jsonl")


def load(path):
    rows = []
    try:
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except FileNotFoundError:
        return []
    return rows


def dig(row, *keys, default=None):
    node = row
    for key in keys:
        if not isinstance(node, dict) or key not in node:
            return default
        node = node[key]
    return node if node is not None else default


def pct(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return ordered[index]


def fmt(value, suffix="", width=None, digits=1):
    if value is None:
        text = "-"
    elif isinstance(value, float):
        text = ("%%.%df" % digits) % value + suffix
    else:
        text = str(value) + suffix
    return text.rjust(width) if width else text


def segments(rows):
    """Split into runs of one app process — counters reset across restarts."""
    out, current, pid = [], [], None
    for row in rows:
        row_pid = dig(row, "app", "pid")
        if row_pid is None:
            continue
        if pid is not None and row_pid != pid:
            out.append(current)
            current = []
        pid = row_pid
        current.append(row)
    if current:
        out.append(current)
    return out


def floor_buckets(points, bucket_seconds=1800):
    """Per-bucket (hours_in, floor, median, ceiling) for a footprint series.

    Footprint swings by hundreds of MB with load — inside one hour this run has
    seen 216MB and 1250MB — so a fit over the raw samples largely measures how
    busy the machine was. A leak instead raises the *minimum* the process ever
    returns to, and load noise cannot lift a floor. So the floor is the honest
    growth signal and the raw slope is the noisy one.
    """
    if len(points) < 6:
        return []
    start = points[0][0]
    buckets = {}
    for epoch, value in points:
        buckets.setdefault(int((epoch - start) // bucket_seconds), []).append(value)
    out = []
    for key in sorted(buckets):
        values = sorted(buckets[key])
        out.append({
            "hours_in": round(key * bucket_seconds / 3600.0, 2),
            "floor_mb": values[0],
            "median_mb": values[len(values) // 2],
            "ceiling_mb": values[-1],
            "samples": len(values),
        })
    return out


def slope_per_hour(points):
    """Least-squares slope of value over time, in units per hour."""
    if len(points) < 3:
        return None
    n = len(points)
    mean_x = sum(p[0] for p in points) / n
    mean_y = sum(p[1] for p in points) / n
    num = sum((x - mean_x) * (y - mean_y) for x, y in points)
    den = sum((x - mean_x) ** 2 for x in [p[0] for p in points])
    if den == 0:
        return None
    return num / den * 3600


def analyse(rows):
    live = [r for r in rows if dig(r, "app")]
    report = {"samples": len(rows), "samples_with_app": len(live)}
    if not rows:
        return report

    report["window"] = {
        "from": rows[0].get("ts"),
        "to": rows[-1].get("ts"),
        "hours": round((rows[-1]["epoch"] - rows[0]["epoch"]) / 3600.0, 2),
    }
    report["app_down_samples"] = sum(1 for r in rows if r.get("app_down"))

    gaps = []
    for prev, cur in zip(rows, rows[1:]):
        span = cur["epoch"] - prev["epoch"]
        if span > 300:
            gaps.append({"from": prev["ts"], "to": cur["ts"], "minutes": round(span / 60.0, 1)})
    report["gaps"] = gaps

    segs = segments(rows)
    report["restarts"] = max(0, len(segs) - 1)
    report["segments"] = [
        {
            "pid": dig(seg[0], "app", "pid"),
            "from": seg[0]["ts"],
            "to": seg[-1]["ts"],
            "hours": round((seg[-1]["epoch"] - seg[0]["epoch"]) / 3600.0, 2),
            "samples": len(seg),
        }
        for seg in segs
    ]

    blocks = [dig(r, "probe", "main_block_ms", default=0.0) for r in live]
    report["main_thread"] = {
        "p50_ms": pct(blocks, 0.50),
        "p95_ms": pct(blocks, 0.95),
        "max_ms": max(blocks) if blocks else None,
        "over_500ms": sum(1 for b in blocks if b > 500),
        "over_1s": sum(1 for b in blocks if b > 1000),
        "over_3s": sum(1 for b in blocks if b > 3000),
        "probe_errors": sum(1 for r in live if dig(r, "probe", "error")),
    }

    cpus = [dig(r, "app", "cpu_pct_interval") for r in live]
    cpus = [c for c in cpus if c is not None]
    report["cpu"] = {
        "p50_pct": pct(cpus, 0.50),
        "p95_pct": pct(cpus, 0.95),
        "max_pct": max(cpus) if cpus else None,
        "over_100pct": sum(1 for c in cpus if c > 100),
    }

    foots = [(r["epoch"], dig(r, "mem", "footprint_mb")) for r in live if dig(r, "mem", "footprint_mb")]
    mem = {
        "first_mb": foots[0][1] if foots else None,
        "last_mb": foots[-1][1] if foots else None,
        "max_mb": max(v for _, v in foots) if foots else None,
    }
    longest = max(segs, key=len) if segs else []
    seg_foots = [(r["epoch"], dig(r, "mem", "footprint_mb")) for r in longest if dig(r, "mem", "footprint_mb")]
    span_hours = (seg_foots[-1][0] - seg_foots[0][0]) / 3600.0 if len(seg_foots) > 1 else 0.0
    mem["growth_window_hours"] = round(span_hours, 2)
    # Extrapolating a slope from a few minutes produces confident nonsense, so
    # it is only reported once a run is long enough to mean something.
    growth = slope_per_hour(seg_foots) if span_hours >= 1.0 else None
    mem["growth_mb_per_hour"] = round(growth, 2) if growth is not None else None

    buckets = floor_buckets(seg_foots)
    mem["floor_buckets"] = buckets
    if len(buckets) >= 3:
        mem["floor_first_mb"] = buckets[0]["floor_mb"]
        mem["floor_last_mb"] = buckets[-1]["floor_mb"]
        floor_slope = slope_per_hour([(b["hours_in"] * 3600, b["floor_mb"]) for b in buckets])
        mem["floor_mb_per_hour"] = round(floor_slope, 2) if floor_slope is not None else None
        # A floor that only ever rises is the signature; one that comes back down
        # is the allocator returning memory, i.e. load rather than a leak.
        falls = sum(1 for a, b in zip(buckets, buckets[1:]) if b["floor_mb"] < a["floor_mb"])
        mem["floor_declines"] = falls
        mem["floor_buckets_count"] = len(buckets)
    threads = [dig(r, "app", "threads") for r in live]
    threads = [t for t in threads if t]
    mem["threads_first"] = threads[0] if threads else None
    mem["threads_max"] = max(threads) if threads else None
    report["memory"] = mem

    panes = [dig(r, "panes", "total") for r in live if dig(r, "panes", "total") is not None]
    running = [dig(r, "panes", "running") for r in live if dig(r, "panes", "running") is not None]
    report["panes"] = {
        "min": min(panes) if panes else None,
        "max": max(panes) if panes else None,
        "avg": round(sum(panes) / len(panes), 1) if panes else None,
        "running_max": max(running) if running else None,
        "mb_per_pane_last": dig(live[-1], "mem", "mb_per_awake_pane") if live else None,
    }

    full_delta = incr_delta = 0
    full_hours = 0.0
    full_avgs, incr_avgs, row_counts = [], [], []
    for seg in segs:
        prev = None
        for row in seg:
            render = row.get("render")
            if not render:
                continue
            row_counts.append(render.get("rows"))
            if render.get("full_avg_ms"):
                full_avgs.append(render["full_avg_ms"])
            if render.get("incr_avg_ms"):
                incr_avgs.append(render["incr_avg_ms"])
            if prev is not None:
                d_full = render["full_count"] - prev[1]
                d_incr = render["incr_count"] - prev[2]
                span = row["epoch"] - prev[0]
                # Negative deltas mean the overview view was rebuilt (counters
                # live on the view instance), not that renders went backwards.
                if d_full >= 0 and d_incr >= 0 and 0 < span < 3600:
                    full_delta += d_full
                    incr_delta += d_incr
                    full_hours += span / 3600.0
            prev = (row["epoch"], render["full_count"], render["incr_count"])
    report["render"] = {
        "observed_hours": round(full_hours, 2),
        "full_renders": full_delta,
        "incremental_updates": incr_delta,
        "full_per_hour": round(full_delta / full_hours, 1) if full_hours else None,
        "incremental_per_hour": round(incr_delta / full_hours, 1) if full_hours else None,
        "full_share_pct": round(100.0 * full_delta / (full_delta + incr_delta), 1)
        if (full_delta + incr_delta)
        else None,
        "full_avg_ms_last": full_avgs[-1] if full_avgs else None,
        "incr_avg_ms_last": incr_avgs[-1] if incr_avgs else None,
        "rows_max": max(r for r in row_counts if r is not None) if row_counts else None,
    }

    swapouts = [(r["epoch"], dig(r, "sys", "swapouts")) for r in rows if dig(r, "sys", "swapouts")]
    swap_rate = None
    if len(swapouts) > 1:
        span = swapouts[-1][0] - swapouts[0][0]
        if span > 0:
            swap_rate = round((swapouts[-1][1] - swapouts[0][1]) / (span / 3600.0), 0)
    report["system"] = {
        "swapouts_per_hour": swap_rate,
        "swap_used_mb_last": dig(rows[-1], "sys", "swap_used_mb"),
        "free_mb_last": dig(rows[-1], "sys", "free_mb"),
        "zmx_procs_last": dig(rows[-1], "zmx", "procs"),
        "zmx_rss_mb_last": dig(rows[-1], "zmx", "rss_mb"),
    }

    report["captures"] = [
        {"ts": r["ts"], "reasons": dig(r, "capture", "reasons"), "sample": dig(r, "capture", "sample")}
        for r in rows
        if r.get("capture")
    ]
    return report


def hourly(rows):
    buckets = {}
    for row in rows:
        if not dig(row, "app"):
            continue
        key = datetime.fromtimestamp(row["epoch"]).strftime("%m-%d %H")
        buckets.setdefault(key, []).append(row)
    lines = []
    for key in sorted(buckets):
        group = buckets[key]
        blocks = [dig(r, "probe", "main_block_ms", default=0.0) for r in group]
        cpus = [c for c in (dig(r, "app", "cpu_pct_interval") for r in group) if c is not None]
        foots = [f for f in (dig(r, "mem", "footprint_mb") for r in group) if f]
        panes = [p for p in (dig(r, "panes", "total") for r in group) if p is not None]
        lines.append(
            "  %s  %s %s  %s %s  %s %s  %s"
            % (
                key,
                fmt(max(foots) if foots else None, width=7),
                fmt(sum(foots) / len(foots) if foots else None, width=7),
                fmt(pct(cpus, 0.95), width=6),
                fmt(max(cpus) if cpus else None, width=6),
                fmt(pct(blocks, 0.95), width=7),
                fmt(max(blocks) if blocks else None, width=8),
                fmt(max(panes) if panes else None, width=5),
            )
        )
    return lines


def render_text(report, rows):
    out = []
    window = report.get("window") or {}
    out.append("Seahelm perf report — %s → %s (%.2fh, %d samples)"
               % (window.get("from"), window.get("to"), window.get("hours", 0), report["samples"]))
    out.append("")

    main = report.get("main_thread") or {}
    out.append("MAIN THREAD (layout.export round trip minus socket ping)")
    out.append("  p50 %s   p95 %s   max %s" % (fmt(main.get("p50_ms"), "ms"), fmt(main.get("p95_ms"), "ms"),
                                               fmt(main.get("max_ms"), "ms")))
    out.append("  stalls >0.5s: %s   >1s: %s   >3s: %s   probe errors: %s"
               % (main.get("over_500ms"), main.get("over_1s"), main.get("over_3s"), main.get("probe_errors")))
    out.append("")

    mem = report.get("memory") or {}
    out.append("MEMORY (app phys_footprint)")
    out.append("  first %s   last %s   max %s" % (fmt(mem.get("first_mb"), "MB"), fmt(mem.get("last_mb"), "MB"),
                                                  fmt(mem.get("max_mb"), "MB")))
    if mem.get("growth_mb_per_hour") is None:
        out.append("  raw fit: needs >=1h in one run to trend (longest so far %sh)"
                   % mem.get("growth_window_hours"))
    else:
        out.append("  raw fit %s per hour over the longest single run (%sh) — noisy, see floor"
                   % (fmt(mem.get("growth_mb_per_hour"), "MB", digits=2), mem.get("growth_window_hours")))

    if mem.get("floor_mb_per_hour") is None:
        out.append("  floor: needs >=3 half-hour buckets in one run")
    else:
        declines = mem.get("floor_declines", 0)
        count = mem.get("floor_buckets_count", 0)
        verdict = ("ratcheting — the floor almost never falls" if declines <= max(1, count // 10)
                   else "floor falls back, so this reads as load, not a leak")
        out.append("  floor %s → %s (%s per hour, %d/%d buckets fell) — %s"
                   % (fmt(mem.get("floor_first_mb"), "MB", digits=0),
                      fmt(mem.get("floor_last_mb"), "MB", digits=0),
                      fmt(mem.get("floor_mb_per_hour"), "MB", digits=1),
                      declines, max(0, count - 1), verdict))
    out.append("  threads %s → max %s" % (mem.get("threads_first"), mem.get("threads_max")))
    out.append("")

    buckets = mem.get("floor_buckets") or []
    if len(buckets) >= 3:
        out.append("MEMORY FLOOR (30-min buckets of the longest run: floor / median / ceiling)")
        for bucket in buckets:
            out.append("  +%5.1fh  %6.0f  %6.0f  %6.0f   (n=%d)"
                       % (bucket["hours_in"], bucket["floor_mb"], bucket["median_mb"],
                          bucket["ceiling_mb"], bucket["samples"]))
        out.append("")

    cpu = report.get("cpu") or {}
    out.append("CPU (interval average from cumulative time)")
    out.append("  p50 %s   p95 %s   max %s   samples >100%%: %s"
               % (fmt(cpu.get("p50_pct"), "%"), fmt(cpu.get("p95_pct"), "%"), fmt(cpu.get("max_pct"), "%"),
                  cpu.get("over_100pct")))
    out.append("")

    render = report.get("render") or {}
    out.append("DASHBOARD RENDER (DEBUG telemetry)")
    if not render.get("rows_max"):
        out.append("  no renders seen yet — these counters only advance while the dashboard is on screen")
    else:
        out.append("  observed %sh   full %s (%s/h)   incremental %s (%s/h)   full share %s"
                   % (render.get("observed_hours"), render.get("full_renders"),
                      fmt(render.get("full_per_hour")), render.get("incremental_updates"),
                      fmt(render.get("incremental_per_hour")), fmt(render.get("full_share_pct"), "%")))
        out.append("  last avg: full %s  incremental %s   max rows %s"
                   % (fmt(render.get("full_avg_ms_last"), "ms", digits=2),
                      fmt(render.get("incr_avg_ms_last"), "ms", digits=2), render.get("rows_max")))
    out.append("")

    panes = report.get("panes") or {}
    system = report.get("system") or {}
    out.append("LOAD & SYSTEM")
    out.append("  panes %s–%s (avg %s, peak running %s)   %s MB per awake pane"
               % (panes.get("min"), panes.get("max"), panes.get("avg"), panes.get("running_max"),
                  panes.get("mb_per_pane_last")))
    out.append("  zmx %s procs / %s MB   swap used %s MB   swapouts %s/h"
               % (system.get("zmx_procs_last"), system.get("zmx_rss_mb_last"),
                  system.get("swap_used_mb_last"), system.get("swapouts_per_hour")))
    out.append("")

    out.append("CONTINUITY")
    out.append("  app restarts: %s   app-down samples: %s   collection gaps: %s"
               % (report.get("restarts"), report.get("app_down_samples"), len(report.get("gaps") or [])))
    for gap in (report.get("gaps") or [])[:5]:
        out.append("    gap %s → %s (%s min)" % (gap["from"], gap["to"], gap["minutes"]))
    out.append("")

    captures = report.get("captures") or []
    out.append("DEEP CAPTURES: %d" % len(captures))
    for capture in captures[:10]:
        out.append("  %s  %s  %s" % (capture["ts"], ",".join(capture["reasons"] or []), capture["sample"]))
    if captures:
        out.append("  (in %s)" % os.path.join(PERF_DIR, "diagnostics"))
    out.append("")

    out.append("HOURLY   footprint max/avg   cpu p95/max   main p95/max   panes")
    out.extend(hourly(rows))
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--last", type=int, help="only the last N samples")
    parser.add_argument("--hours", type=float, help="only the last H hours")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--path", default=SAMPLES_PATH)
    args = parser.parse_args()

    rows = load(args.path)
    if not rows:
        print("no samples yet at %s" % args.path)
        return 1
    if args.hours:
        cutoff = rows[-1]["epoch"] - args.hours * 3600
        rows = [r for r in rows if r["epoch"] >= cutoff]
    if args.last:
        rows = rows[-args.last:]

    report = analyse(rows)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(render_text(report, rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
