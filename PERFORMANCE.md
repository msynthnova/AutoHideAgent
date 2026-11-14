# Performance development and regression checks

All measurements run a development bundle (`com.systems.autohideagent.dev`) with
`--dry-run`. They never install, upgrade, hide, or quit production applications.
Benchmark preferences and file logs are isolated from normal dev/production data.

## Implementation

- `RefreshCoordinator` combines workspace event bursts into one UI refresh after
  50 ms. Activation/deactivation timestamps are still updated immediately.
- `AppMonitor` owns system snapshots and icon caching. An evaluation reuses its
  snapshot for its UI update, avoiding a second system scan. Display-only media
  assertions may be cached for one second. Hide/quit decisions and confirmation
  rechecks always query fresh assertions.
- `ExclusionIndex` normalizes exclusions only when edited, rather than rebuilding
  a set for each app during every evaluation.
- `DiagnosticLogWriter` serializes file writes on a utility queue, reuses its file
  handle, rotates at 1 MB, and exposes an asynchronous flush boundary. Explicit
  shutdown drains pending log entries. The in-app activity list stays main-actor
  isolated and capped at 50 entries.
- `EvaluationScheduler` stops the periodic timer when both features are off and
  uses one one-shot wakeup during a temporary pause. Session sleep/lock suspends
  evaluations. The dashboard refresh task only runs while the app list is visible.
- Models, preference loading, inactivity decisions, system snapshots, refresh
  scheduling, timer scheduling, and file logging have separate source files.

## Correctness tests

```bash
unset SDKROOT && swift test
python3 -m unittest discover -s scripts/tests -v
```

Swift tests verify refresh coalescing/cancellation, fresh protection queries,
exclusion invalidation, timer shutdown and single pause wakeups, decision safety,
log ordering/rotation/errors, and existing UI state behavior. Python tests check
CPU accounting against the process CPU clock and validate memory counters. Protocol tests reject stale counters and ensure repeated runs cannot reuse old response files.

## Repeatable optimized benchmark

Build an optimized **development** bundle, retaining its isolated identity:

```bash
AUTOHIDE_BUILD_CONFIGURATION=release ./bundle.sh debug
python3 scripts/benchmark_app.py \
  --bundle 'build/AutoHideAgent Dev.app' \
  --output build/performance/current.json \
  --duration 20 --repetitions 3 --check
```

The five steady scenarios are background monitoring, both features off, temporary
pause, desktop dashboard, and menu panel. Each is sampled for 20 seconds in three
repetitions. Additional workloads issue 1,000 refresh requests and 1,000 log events.
For a short targeted run, use `--scenarios refreshBurst logBurst`.

`--check` fails if any steady scenario averages over 5% of one CPU core, exceeds
256 MiB physical footprint or 512 MiB RSS, polls evaluation while off/paused, or
rebuilds the app list more than twice for a refresh burst, with a per-event allowance for unrelated workspace activity and evaluation ticks. Resource limits are
configurable CLI options; operation-count regressions have deterministic Swift
coverage. These are regression budgets, not advertised hardware requirements.

CPU uses the change in process user+system CPU counters, converted from Mach ticks
using the machine's timebase, divided by monotonic wall time. 100% means one core.
Memory reports both resident set size and physical footprint. RSS includes shared
framework pages; it is not the same as private memory. Sampled peaks may miss
transients shorter than the sampling interval. The app's own CPU is measured;
WindowServer and other processes are excluded.

Runs on a working desktop are subject to user activity, OS scheduling, caching,
and memory pressure. Compare medians across repetitions, retain raw JSON, and do
not describe tiny idle differences as established speedups. Burst main-thread
submission time is recorded separately from completed work (including log flush).
The fixed 150 ms command-settling delay is not part of the submission metric.

No commit or new release is performed by these checks.

## Measured comparison

The [November 13 report](benchmarks/results/2026-11-13/REPORT.md) includes CPU,
RSS, footprint, exact binary hashes, and retained calibrated JSON. It reports
mixed idle results as well as burst improvements. A repeat run rejected for stale
responses was excluded; subsequent runs use unique response directories and
reject decreasing counters.
