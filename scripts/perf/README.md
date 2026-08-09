# Long-run performance monitoring

Background sampler for the class of problem in issue #35: Seahelm gets slower
the longer it runs, until the main thread is pegged and the machine thrashes.
Point-in-time debugging can't see that — it needs a continuous window across
real usage.

```bash
scripts/perf/perfmon.sh start --hours 48    # default: 48h at 60s
scripts/perf/perfmon.sh status              # job state, deadline, latest sample
scripts/perf/perfmon.sh report              # summary over the whole run
scripts/perf/perfmon.sh report --hours 6    # ...or just the recent window
scripts/perf/perfmon.sh stop                # stop early
```

Sampling is a launchd agent (`com.seahelm.perfmon`), not a foreground loop, so
it survives closing the pane that started it, Seahelm restarts, and sleep/wake.
The job removes itself when the deadline passes. Data lands in
`~/Library/Logs/seahelm-perf/` (`SEAHELM_PERF_DIR` overrides): `samples.jsonl`
one row per sample, previous runs archived as `samples-<stamp>.jsonl`.

## What each signal is for

**Main-thread stall** — `layout.export` goes through `runOnMain`
(`DispatchQueue.main.sync`); `ping` is answered on the socket queue. The
difference is how long the main thread made a caller wait, which is the
user-visible "卡死". Everything else can look fine while this degrades.

**Memory** — the app's own `phys_footprint`/`compressed` (via `app.memory`),
alongside system swap and the cumulative `Swapouts` counter, so app growth is
distinguishable from the machine simply being out of RAM. Thread count comes
along to catch a thread leak.

**Render telemetry** — the DEBUG `[DashboardOverview]` counters, read back out
of the unified log. Counters are cumulative per view instance, so the report
differences them and treats a negative delta as a rebuild, not as progress.
This is what says whether overview updates stayed incremental under load.

**Load context** — pane/worktree counts per sample, so a regression can be read
against how much work was actually on screen rather than against wall time.

CPU comes from differencing cumulative CPU time between samples, not from `ps
%cpu` (a decaying average, kept only as a cross-check).

## Deep captures

When a sample trips a threshold — main-thread block >1.5s, footprint >2GB,
sustained >150% CPU for 3 samples, or a probe error — the sampler writes
`sample` + `vmmap -summary` into `diagnostics/` and names the reason in the
row. Rate-limited to one capture per 15 minutes, because `sample` alone costs
several seconds of CPU.

## Reading the result

`report` prints stall percentiles, footprint growth per hour (only once a
single run exceeds an hour — a slope from a few minutes is noise), full vs
incremental render share, and an hourly table. The headline questions:

- does `main p95/max` climb over the run, or stay flat?
- is `growth MB per hour` near zero, or does footprint ratchet up?
- does `full share` stay low, i.e. did the structure signature keep holding?
