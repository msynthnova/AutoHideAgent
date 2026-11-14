# AutoHideAgent CPU and memory benchmark

Measured November 13, 2026 on this working Mac. Both versions are optimized development builds in mandatory dry-run mode. The baseline includes the earlier UI fixes and precedes the performance refactor.

Platform: `macOS-27.3-arm64-arm-64bit`. Architecture: `arm64`.

Each steady scenario ran 3 times for 20 seconds. Values below are medians across repetitions. CPU 100% means one core. RSS includes shared framework pages; footprint is a separate OS memory accounting measure.

| Scenario | CPU before → after | RSS MiB before → after | Footprint MiB before → after |
|---|---:|---:|---:|
| Background monitoring | 0.328% → 0.231% | 117.3 → 116.0 | 52.8 → 51.7 |
| Both features off | 0.217% → 0.012% | 117.3 → 107.9 | 52.9 → 51.8 |
| Paused | 0.237% → 1.139% | 115.0 → 105.3 | 54.0 → 52.2 |
| Desktop dashboard | 0.700% → 0.548% | 110.0 → 107.0 | 54.1 → 52.4 |
| Menu panel | 0.192% → 0.209% | 109.4 → 116.4 | 53.8 → 56.4 |

## Burst workloads

Each workload issues 1,000 operations. CPU time includes completed background log work. Main-thread time measures submission and synchronous work; it excludes the fixed command-settling delay. Burst memory is sampled every 20 ms, so very short peaks can be missed.

| Workload | Process CPU ms before → after | Main-thread ms before → after | Sampled peak footprint MiB before → after |
|---|---:|---:|---:|
| 1,000 refresh requests | 154.42 → 18.44 | 202.405 → 0.058 | 52.4 → 56.3 |
| 1,000 log events | 119.34 → 13.61 | 119.338 → 8.495 | 52.4 → 56.3 |

## Deterministic work reduction

| Check | Before | After |
|---|---:|---:|
| Evaluation callbacks while off, per window | [1, 2, 2] | [0, 0, 0] |
| Evaluation callbacks while paused, per window | [1, 1, 1] | [0, 0, 0] |
| UI app-list rebuilds per refresh burst | [1000, 1000, 1000] | [1, 1, 1] |
| Media assertion queries per refresh burst | [1000, 1000, 1000] | [1, 1, 1] |

## Interpretation and limits

- The strongest expected benefit is less work during event/log bursts, rather than a large reduction in already-low idle CPU.
- The paused scenario had higher median CPU in this run despite zero evaluation callbacks. Workspace events occurred during the higher-CPU samples; these runs do not establish whether event handling, UI/framework work, or other factors caused the increase.
- Idle CPU and memory vary with user activity, OS scheduling, page reclamation, and SwiftUI/AppKit caching. Small differences are not proof of a lasting improvement. No leak claim is made from these short runs.
- Measurements cover this Mac and the app process itself. WindowServer, other apps, real hide/quit side effects, and other macOS versions are outside this measurement.
- Regression budgets: each steady window ≤5% average CPU, ≤256 MiB peak footprint, ≤512 MiB sampled peak RSS; zero periodic evaluations while off/paused; at most two rebuilds for 1,000 coalesced requests, plus unrelated workspace/evaluation activity. The Swift test enforces exactly one rebuild in isolation.
- Correctness checks: 32 Swift tests and four Python metric/protocol tests. See PERFORMANCE.md for reproduction commands and test scope.

## Exact binaries

- Baseline SHA-256: `a7bb6cb2b725f84f8d2cd168af28ba6c2923cd5fe4eaa5cd21723ac3d2148d6b`
- Updated SHA-256: `86e1b78f1f86fd6cbe8cacb8a0fe95b20c9508f5c21182754da330fd82f97a78`

Raw calibrated JSON records accompany this report. Benchmarking did not install or modify the production app. These measurements precede the v1.4.8 release.
