import importlib.util
import os
from pathlib import Path
import platform
import time
import unittest
import tempfile

spec = importlib.util.spec_from_file_location('benchmark_app', Path(__file__).resolve().parents[1] / 'benchmark_app.py')
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)

@unittest.skipUnless(platform.system() == 'Darwin', 'macOS process accounting')
class BenchmarkMetricTests(unittest.TestCase):
    def test_cpu_units_match_process_clock(self):
        initial = benchmark.usage(os.getpid())
        start = time.process_time()
        while time.process_time() - start < 0.1:
            pass
        elapsed_cpu = time.process_time() - start
        final = benchmark.usage(os.getpid())
        measured = (final.user + final.system - initial.user - initial.system) * benchmark.cpu_tick_seconds()
        self.assertAlmostEqual(measured, elapsed_cpu, delta=0.02)

    def test_memory_fields_are_populated(self):
        value = benchmark.usage(os.getpid())
        self.assertGreater(value.rss, 0)
        self.assertGreater(value.footprint, 0)
        self.assertLess(value.rss, 100 * 2**30)
        self.assertLess(value.footprint, 100 * 2**30)

class BenchmarkProtocolTests(unittest.TestCase):
    def test_repeated_output_path_uses_fresh_responses(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'same-report.json'
            first = benchmark.new_run_directory(output)
            (first / '001-status.json').write_text('{"stale":true}')
            second = benchmark.new_run_directory(output)
            self.assertNotEqual(first, second)
            self.assertFalse((second / '001-status.json').exists())

    def test_stale_counters_are_rejected(self):
        self.assertEqual(benchmark.metric_delta({'appScans': 10}, {'appScans': 11}), {'appScans': 1})
        with self.assertRaises(ValueError):
            benchmark.metric_delta({'appScans': 10}, {'appScans': 9})

if __name__ == '__main__':
    unittest.main()
