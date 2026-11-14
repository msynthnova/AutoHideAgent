#!/usr/bin/env python3
"""Create a readable comparison from the retained process benchmark JSON files."""
import argparse
import json
from pathlib import Path
import statistics


def load(path):
    data = json.loads(path.read_text())
    if len(data['records']) != data['repetitions'] * len(data.get('scenarios', range(7))):
        raise ValueError(f'Incomplete benchmark: {path}')
    if 'cpuTickSeconds' not in data:
        raise ValueError(f'CPU units not calibrated: {path}')
    return data


def median(rows, key):
    return statistics.median(row[key] for row in rows)


def group(data, scenario):
    return [row for row in data['records'] if row['scenario'] == scenario]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--before-bursts', type=Path)
    parser.add_argument('--after-bursts', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    before, after = load(args.before), load(args.after)
    before_bursts = load(args.before_bursts) if args.before_bursts else before
    after_bursts = load(args.after_bursts) if args.after_bursts else after
    assert before['executableSHA256'] == before_bursts['executableSHA256']
    assert after['executableSHA256'] == after_bursts['executableSHA256']
    lines = ['# AutoHideAgent CPU and memory benchmark', '',
             'Measured November 13, 2026 on this working Mac. Both versions are optimized development builds in mandatory dry-run mode. The baseline includes the earlier UI fixes and precedes the performance refactor.', '',
             f"Platform: `{after['platform']}`. Architecture: `{after['architecture']}`.", '',
             f"Each steady scenario ran {after['repetitions']} times for {after['durationSeconds']:g} seconds. Values below are medians across repetitions. CPU 100% means one core. RSS includes shared framework pages; footprint is a separate OS memory accounting measure.", '',
             '| Scenario | CPU before → after | RSS MiB before → after | Footprint MiB before → after |',
             '|---|---:|---:|---:|']
    labels = {'background': 'Background monitoring', 'off': 'Both features off', 'paused': 'Paused',
              'dashboard': 'Desktop dashboard', 'menu': 'Menu panel'}
    for scenario, label in labels.items():
        old, new = group(before, scenario), group(after, scenario)
        lines.append(f'| {label} | {median(old,"cpuPercent"):.3f}% → {median(new,"cpuPercent"):.3f}% | '
                     f'{median(old,"rssMiBMedian"):.1f} → {median(new,"rssMiBMedian"):.1f} | '
                     f'{median(old,"footprintMiBMedian"):.1f} → {median(new,"footprintMiBMedian"):.1f} |')
    lines += ['', '## Burst workloads', '',
              'Each workload issues 1,000 operations. CPU time includes completed background log work. Main-thread time measures submission and synchronous work; it excludes the fixed command-settling delay. Burst memory is sampled every 20 ms, so very short peaks can be missed.', '',
              '| Workload | Process CPU ms before → after | Main-thread ms before → after | Sampled peak footprint MiB before → after |',
              '|---|---:|---:|---:|']
    for scenario, label in [('refreshBurst', '1,000 refresh requests'), ('logBurst', '1,000 log events')]:
        old, new = group(before_bursts, scenario), group(after_bursts, scenario)
        lines.append(f'| {label} | {1000*median(old,"cpuSeconds"):.2f} → {1000*median(new,"cpuSeconds"):.2f} | '
                     f'{median(old,"mainThreadMilliseconds"):.3f} → {median(new,"mainThreadMilliseconds"):.3f} | '
                     f'{median(old,"footprintMiBPeak"):.1f} → {median(new,"footprintMiBPeak"):.1f} |')
    lines += ['', '## Deterministic work reduction', '',
              '| Check | Before | After |', '|---|---:|---:|']
    for scenario in ['off', 'paused']:
        old = [r['metrics']['evaluationCallbacks'] for r in group(before, scenario)]
        new = [r['metrics']['evaluationCallbacks'] for r in group(after, scenario)]
        lines.append(f'| Evaluation callbacks while {scenario}, per window | {old} | {new} |')
    for metric, label in [('appScans', 'UI app-list rebuilds per refresh burst'), ('powerAssertionQueries', 'Media assertion queries per refresh burst')]:
        old = [r['metrics'][metric] for r in group(before_bursts, 'refreshBurst')]
        new = [r['metrics'][metric] for r in group(after_bursts, 'refreshBurst')]
        lines.append(f'| {label} | {old} | {new} |')
    lines += ['', '## Interpretation and limits', '',
              '- The strongest expected benefit is less work during event/log bursts, rather than a large reduction in already-low idle CPU.',
              '- The paused scenario had higher median CPU in this run despite zero evaluation callbacks. Workspace events occurred during the higher-CPU samples; these runs do not establish whether event handling, UI/framework work, or other factors caused the increase.',
              '- Idle CPU and memory vary with user activity, OS scheduling, page reclamation, and SwiftUI/AppKit caching. Small differences are not proof of a lasting improvement. No leak claim is made from these short runs.',
              '- Measurements cover this Mac and the app process itself. WindowServer, other apps, real hide/quit side effects, and other macOS versions are outside this measurement.',
              '- Regression budgets: each steady window ≤5% average CPU, ≤256 MiB peak footprint, ≤512 MiB sampled peak RSS; zero periodic evaluations while off/paused; at most two rebuilds for 1,000 coalesced requests, plus unrelated workspace/evaluation activity. The Swift test enforces exactly one rebuild in isolation.',
              '- Correctness checks: 32 Swift tests and four Python metric/protocol tests. See PERFORMANCE.md for reproduction commands and test scope.', '',
              '## Exact binaries', '',
              f'- Baseline SHA-256: `{before["executableSHA256"]}`',
              f'- Updated SHA-256: `{after["executableSHA256"]}`', '',
              'Raw calibrated JSON records accompany this report. Benchmarking did not install or modify the production app. These measurements precede the v1.4.8 release.', '']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text('\n'.join(lines))
    print(args.output)

if __name__ == '__main__':
    main()
