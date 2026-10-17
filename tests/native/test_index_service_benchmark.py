import importlib.util
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("index_service_benchmark",
    Path(__file__).resolve().parents[2] / "scripts" / "benchmark-index-service.py")
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class Process:
    def __init__(self, lines, returncode=0):
        self.stdout = io.StringIO(lines)
        self.stdin = io.StringIO()
        self.returncode = returncode
        self.pid = 0

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        return self.returncode


class ServiceBenchmarkTests(unittest.TestCase):
    def run_trial(self, lines, returncode=0):
        arguments = SimpleNamespace(folder=[], code_root=[], timeout=2, backend="amd-vulkan", gpu="fixture")
        with tempfile.TemporaryDirectory() as root:
            with patch.object(benchmark.subprocess, "Popen", return_value=Process(lines, returncode)), \
                    patch.object(benchmark, "psutil", None):
                return benchmark.trial(Path("fixture-helper"), Path(root) / "trial", arguments, {})

    def test_final_counts_are_required_before_reporting_throughput(self):
        for reply in ['{"event":"exit"}\n', '{"event":"idle","pending":1,"vectors":2}\n',
                      '{"event":"idle","unfinished":1,"vectors":2}\n', '{"event":"idle","vectors":0}\n']:
            with self.subTest(reply=reply), self.assertRaises(ValueError):
                self.run_trial(reply)

    def test_nonzero_exit_and_service_errors_are_failures(self):
        with self.assertRaises(RuntimeError):
            self.run_trial('{"event":"idle","vectors":1}\n', returncode=1)
        with self.assertRaisesRegex(RuntimeError, "selected device unavailable"):
            self.run_trial('{"event":"error","message":"selected device unavailable"}\n')

    def test_success_keeps_work_counts_and_unknown_memory(self):
        row = self.run_trial('{"event":"file","state":"done"}\n'
            '{"event":"file","state":"partial"}\n'
            '{"event":"idle","files":2,"searchable":2,"vectors":3}\n')
        self.assertEqual(row["completedWork"]["vectors"], 3)
        self.assertEqual(row["completionGapsMs"]["samples"], 1)
        self.assertIsNone(row["memory"]["peakProcessTreeRSSBytes"])
        self.assertIsNone(row["peakDedicatedGPUMemoryBytes"])

    def test_device_or_policy_mismatch_is_rejected(self):
        info = {"backend":"amd-vulkan","device_id":"fixture","revision":"fixture","dim":768,
                "execution_policy":"accelerator-only"}
        self.assertEqual(benchmark.validate_receipt(info, "amd-vulkan", "fixture"), info)
        with self.assertRaises(ValueError):
            benchmark.validate_receipt(info, "amd-vulkan", "another-device")
        with self.assertRaises(ValueError):
            benchmark.validate_receipt({**info,"execution_policy":"cpu"}, "amd-vulkan", "fixture")

    def test_workload_changes_are_detected_without_changing_source_files(self):
        with tempfile.TemporaryDirectory() as root:
            folder = Path(root)
            file = folder / "Café.txt"
            file.write_text("first document", encoding="utf-8")
            first = benchmark.workload_manifest([folder])
            self.assertEqual(first, benchmark.workload_manifest([folder]))
            file.write_text("second document", encoding="utf-8")
            self.assertNotEqual(first["sha256"], benchmark.workload_manifest([folder])["sha256"])


if __name__ == "__main__":
    unittest.main()
