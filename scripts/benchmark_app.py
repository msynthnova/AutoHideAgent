#!/usr/bin/env python3
"""Benchmark a development .app in mandatory dry-run mode on macOS.

CPU converts Mach ticks to seconds, then divides delta(user+system)/wall time, where 100% means one core.
Memory comes from proc_pid_rusage: RSS and physical footprint, in MiB.
No production app is launched, installed, or modified.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent

class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        'user', 'system', 'idle_wakeups', 'interrupt_wakeups', 'pageins', 'wired', 'rss', 'footprint',
        'start', 'exit', 'child_user', 'child_system', 'child_idle', 'child_interrupt', 'child_pageins',
        'child_elapsed', 'disk_read', 'disk_written')]

libproc = None

class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

def cpu_tick_seconds():
    value = Timebase()
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    if library.mach_timebase_info(ctypes.byref(value)) != 0 or not value.denom:
        raise RuntimeError('Cannot determine Mach CPU timebase')
    return value.numer / value.denom / 1e9


def usage(pid):
    global libproc
    if libproc is None:
        libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        libproc.proc_pid_rusage.restype = ctypes.c_int
    value = Usage()
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(value)):
        raise OSError(ctypes.get_errno(), 'proc_pid_rusage failed')
    return value


def new_run_directory(output):
    directory = output.parent / (output.stem + '-samples-' + uuid.uuid4().hex[:12])
    directory.mkdir(parents=True, exist_ok=False)
    return directory


def metric_delta(before, after):
    result = {key: after[key] - before[key] for key in before}
    if any(value < 0 for value in result.values()):
        raise ValueError('Non-monotonic runtime counters: stale or mismatched benchmark response')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duration', type=float, default=20)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--iterations', type=int, default=1000)
    parser.add_argument('--scenarios', nargs='+', choices=['background', 'off', 'paused', 'dashboard', 'menu', 'refreshBurst', 'logBurst'],
                        default=['background', 'off', 'paused', 'dashboard', 'menu', 'refreshBurst', 'logBurst'])
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--max-idle-cpu', type=float, default=5)
    parser.add_argument('--max-footprint-mib', type=float, default=256)
    parser.add_argument('--max-rss-mib', type=float, default=512)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or args.duration <= 0 or args.repetitions < 1 or not 1 <= args.iterations <= 10_000:
        parser.error('Requires macOS, a positive duration, and at least one repetition')
    bundle = args.bundle.resolve()
    identifier = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier',
                                         str(bundle / 'Contents/Info.plist')], text=True).strip()
    if identifier != 'com.systems.autohideagent.dev':
        parser.error('Refusing to benchmark a production or unknown bundle')
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    scratch = new_run_directory(output)
    helper = scratch / 'post-notification'
    helper_source = scratch / 'post-notification.swift'
    helper_source.write_text('''import Foundation
DistributedNotificationCenter.default().postNotificationName(
 Notification.Name("com.systems.autohideagent.dev.benchmark"), object: CommandLine.arguments[1],
 userInfo: nil, deliverImmediately: true)
''')
    subprocess.run(['swiftc', str(helper_source), '-o', str(helper)], check=True, capture_output=True)
    executable = bundle / 'Contents/MacOS/AutoHideAgent'
    environment = os.environ.copy()
    environment['AUTOHIDE_BENCHMARK_DIRECTORY'] = str(scratch)
    log = (scratch / 'process.log').open('w')
    process = subprocess.Popen([str(executable), '--dry-run'], env=environment, stdout=log, stderr=log)
    sequence = 0

    def command(action, sample=None):
        nonlocal sequence
        sequence += 1
        result_path = scratch / f'{sequence:03d}-{action}.json'
        payload = {'action': action, 'output': str(result_path), 'iterations': args.iterations}
        subprocess.run([str(helper), json.dumps(payload)], check=True)
        deadline = time.monotonic() + 60
        while not result_path.exists():
            if process.poll() is not None:
                raise RuntimeError(f'App exited with {process.returncode}; see {scratch / "process.log"}')
            if time.monotonic() > deadline:
                raise TimeoutError('Benchmark command timed out: ' + action)
            if sample:
                sample()
            time.sleep(0.02)
        return json.loads(result_path.read_text())

    def measure(action, trial, seconds=None):
        before_metrics = command('status')['metrics']
        if seconds is not None:
            command(action)
            time.sleep(0.4)
            before_metrics = command('status')['metrics']
        started = time.monotonic()
        initial = usage(process.pid)
        samples = []
        response = None
        if seconds is None:
            samples.append(initial)
            response = command(action, sample=lambda: samples.append(usage(process.pid)))
            samples.append(usage(process.pid))
        else:
            while time.monotonic() - started < seconds:
                time.sleep(min(0.5, max(0, seconds - (time.monotonic() - started))))
                samples.append(usage(process.pid))
        finished = time.monotonic()
        final = usage(process.pid)
        after_metrics = command('status')['metrics']
        result = {
            'scenario': action, 'trial': trial, 'wallSeconds': finished - started,
            'cpuSeconds': ((final.user + final.system) - (initial.user + initial.system)) * tick_seconds,
            'cpuPercent': 100 * ((final.user + final.system) - (initial.user + initial.system)) * tick_seconds / (finished - started),
            'rssMiBMedian': statistics.median(s.rss / 2**20 for s in samples),
            'rssMiBPeak': max(s.rss / 2**20 for s in samples),
            'footprintMiBMedian': statistics.median(s.footprint / 2**20 for s in samples),
            'footprintMiBPeak': max(s.footprint / 2**20 for s in samples),
            'idleWakeups': final.idle_wakeups - initial.idle_wakeups,
            'metrics': metric_delta(before_metrics, after_metrics),
        }
        if response:
            result['mainThreadMilliseconds'] = response['mainThreadMilliseconds']
            result['completedMilliseconds'] = response['completedMilliseconds']
            result['iterations'] = args.iterations
        print(f'{action} trial {trial}: CPU {result["cpuPercent"]:.3f}%, RSS {result["rssMiBMedian"]:.1f} MiB, footprint {result["footprintMiBMedian"]:.1f} MiB', flush=True)
        return result

    tick_seconds = cpu_tick_seconds()
    records = []
    try:
        time.sleep(3)
        for trial in range(1, args.repetitions + 1):
            for scenario in args.scenarios:
                if scenario in ['refreshBurst', 'logBurst']:
                    command('background')
                    records.append(measure(scenario, trial))
                else:
                    records.append(measure(scenario, trial, args.duration))
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
        subprocess.run(['defaults', 'delete', f'AutoHideAgent.Benchmark.{process.pid}'], capture_output=True)
        report = {
            'runDirectory': scratch.name,
            'platform': platform.platform(), 'architecture': platform.machine(),
            'configuration': 'optimized development bundle, dry-run',
            'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
            'durationSeconds': args.duration, 'repetitions': args.repetitions,
            'scenarios': args.scenarios, 'complete': len(records) == args.repetitions * len(args.scenarios),
            'samplingNote': 'Steady-state memory sampled every 500 ms; burst memory sampled every 20 ms. Sampled peaks may miss shorter transients.',
            'cpuDefinition': '100% = one CPU core; Mach timebase converted delta user+system CPU divided by wall time',
            'cpuTickSeconds': tick_seconds,
            'records': records,
        }
        output.write_text(json.dumps(report, indent=2) + '\n')
    if args.check:
        for record in records:
            if record['scenario'] not in ['refreshBurst', 'logBurst']:
                assert record['cpuPercent'] <= args.max_idle_cpu, record
                assert record['footprintMiBPeak'] <= args.max_footprint_mib, record
                assert record['rssMiBPeak'] <= args.max_rss_mib, record
            if record['scenario'] in ['off', 'paused']:
                assert record['metrics']['evaluationCallbacks'] == 0, record
            if record['scenario'] == 'refreshBurst':
                ambient_requests = max(0, record['metrics']['refreshRequests'] - record['iterations'])
                allowed = 2 + ambient_requests + record['metrics']['evaluationCallbacks']
                assert record['metrics']['appScans'] <= allowed, record
        print('Performance regression budgets passed.', flush=True)
    print(output)

if __name__ == '__main__':
    main()
