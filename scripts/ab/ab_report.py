#!/usr/bin/env python3
"""Report on an A/B stretch (see ab_record.py): how the macOS app and the
GPUI client / seahelm-core compared over the same time.

  ab_report.py [--hours N]     (default: everything since `ab.sh start`)

Sections:
  detection   app vs core status on the same panes (core-shadow.jsonl, plus a
              per-transition comparison of app-events vs core-events)
  turns       agent turns that ended (Running → Idle/Waiting), per side
  notices     banners the core decided, and how many the GPUI client showed
  use         what was done in the GPUI client (gpui-events.jsonl)
  resources   CPU and memory per process group (samples.jsonl)
"""
import json
import os
import statistics
import sys
import time
from collections import Counter, defaultdict

AB = os.environ.get("SEAHELM_AB_DIR", os.path.expanduser("~/Library/Logs/seahelm-ab"))
CFG = os.path.expanduser("~/.config/seahelm")


def read(path, since, key):
    out = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                t = r.get(key) or r.get("recorded_at") or r.get("at") or 0
                if t >= since:
                    out.append(r)
    except FileNotFoundError:
        pass
    return out


def started_at():
    try:
        with open(os.path.join(AB, "state.json")) as f:
            return json.load(f).get("started_at", 0)
    except (FileNotFoundError, ValueError):
        return 0


def fmt_dur(s):
    s = int(s)
    return f"{s // 3600}h{(s % 3600) // 60:02d}m" if s >= 3600 else f"{s // 60}m{s % 60:02d}s"


def section(title):
    print(f"\n== {title} ==")


def main():
    hours = None
    if "--hours" in sys.argv:
        hours = float(sys.argv[sys.argv.index("--hours") + 1])
    since = time.time() - hours * 3600 if hours else started_at()
    span = time.time() - since if since else 0
    print(f"A/B report — window {fmt_dur(span) if span else 'all'} (data: {AB})")

    app = read(os.path.join(AB, "app-events.jsonl"), since, "recorded_at")
    core = read(os.path.join(CFG, "core-events.jsonl"), since, "logged_at")
    shadow = read(os.path.join(CFG, "core-shadow.jsonl"), since, "at")
    gpui = read(os.path.join(CFG, "gpui-events.jsonl"), since, "at")
    samples = read(os.path.join(AB, "samples.jsonl"), since, "recorded_at")

    # Detection: the shadow log's disagreements, by (app, core) pair.
    section("detection (app vs core, same panes)")
    pairs = Counter()
    lasting = defaultdict(float)
    summaries = [r for r in shadow if r.get("kind") == "summary" or "agreement" in r]
    for r in shadow:
        a, c = r.get("app"), r.get("core")
        if a is not None and c is not None:
            pairs[(a, c)] += 1
            lasting[(a, c)] += float(r.get("seconds", r.get("lasted", 0)) or 0)
    if summaries:
        print(f"  latest shadow summary: {json.dumps(summaries[-1], ensure_ascii=False)[:300]}")
    # The comparator prints its running agreement to its own log.
    try:
        with open(os.path.join(AB, "shadow.log")) as f:
            agree = [l.strip() for l in f if "agree" in l]
        if agree:
            print(f"  {agree[-1].removeprefix('shadow: ')}")
    except FileNotFoundError:
        pass
    if pairs:
        print("  disagreements that outlasted the grace period (app → core):")
        for (a, c), n in pairs.most_common(10):
            print(f"    {a:>10} vs {c:<10} ×{n}  total {fmt_dur(lasting[(a, c)])}")
    else:
        print("  no lasting disagreements logged" + ("" if shadow else " (is `seahelm-core shadow --follow-app` running?)"))

    # Transitions per pane on each side, matched by session key within 20 s.
    def transitions(events, pane_key, t_key):
        out = defaultdict(list)
        for e in events:
            if e.get("type") != "pane.status_changed":
                continue
            p = e.get(pane_key) or e.get("pane_session_key") or e.get("pane_id")
            out[p].append((e.get(t_key) or e.get("recorded_at") or 0, e.get("old_status"), e.get("status")))
        return out

    ta = transitions(app, "pane_session_key", "recorded_at")
    tc = transitions(core, "pane_session_key", "logged_at")
    shared = set(ta) & set(tc)
    matched, lags, only_app, only_core = 0, [], 0, 0
    for p in shared:
        cs = list(tc[p])
        for t, _, new in ta[p]:
            hit = next((x for x in cs if x[2] == new and abs(x[0] - t) <= 20), None)
            if hit:
                matched += 1
                lags.append(hit[0] - t)
                cs.remove(hit)
            else:
                only_app += 1
        only_core += len(cs)
    print(f"  panes seen by both: {len(shared)} · transitions matched {matched}, app only {only_app}, core only {only_core}")
    if lags:
        print(f"  core lag behind app on matched transitions: median {statistics.median(lags):+.1f}s, "
              f"p90 {sorted(lags)[int(len(lags) * 0.9) - 1 if len(lags) > 1 else 0]:+.1f}s")

    section("turns ended (Running → Idle / Waiting)")
    def ends(tr):
        return sum(1 for evs in tr.values() for _, old, new in evs if old == "Running" and new in ("Idle", "Waiting"))
    gp = {p for p in tc if str(p).startswith("gpui-")}
    print(f"  app panes (app's view): {ends(ta)}")
    print(f"  app panes (core's view): {ends({p: v for p, v in tc.items() if p not in gp})}")
    print(f"  GPUI panes (core): {ends({p: tc[p] for p in gp})}")

    section("notices")
    notices = [e for e in core if e.get("type") == "pane.notice"]
    shown = [e for e in gpui if e.get("event") == "notice" and e.get("shown")]
    print(f"  core decided: {len(notices)} (GPUI panes {sum(1 for n in notices if str(n.get('pane_session_key','')).startswith('gpui-'))})"
          f" · GPUI client showed: {len(shown)}")

    section("use of the GPUI client")
    if gpui:
        c = Counter(e.get("event") for e in gpui)
        print("  " + ", ".join(f"{k} {v}" for k, v in c.most_common()))
        active, last_on = 0.0, None
        for e in gpui:
            if e.get("event") in ("activate", "launch"):
                last_on = e.get("at")
            elif e.get("event") == "deactivate" and last_on:
                active += e.get("at", 0) - last_on
                last_on = None
        print(f"  time frontmost: {fmt_dur(active)}")
    else:
        print("  no GPUI client events")

    section("resources (per sample: mean / max)")
    agg = defaultdict(lambda: {"cpu": [], "rss": [], "procs": []})
    for s in samples:
        for g, v in s.get("groups", {}).items():
            agg[g]["cpu"].append(v["cpu"])
            agg[g]["rss"].append(v["rss_mb"])
            agg[g]["procs"].append(v["procs"])
    if not agg:
        print("  no samples")
    for g in ["app", "gpui", "core", "seahelmd-app", "seahelmd-gpui"]:
        if g in agg:
            a = agg[g]
            print(f"  {g:<14} CPU {statistics.mean(a['cpu']):5.1f}% / {max(a['cpu']):5.1f}%   "
                  f"RSS {statistics.mean(a['rss']):7.1f} / {max(a['rss']):7.1f} MB   procs {max(a['procs'])}   ({len(a['cpu'])} samples)")


if __name__ == "__main__":
    main()
