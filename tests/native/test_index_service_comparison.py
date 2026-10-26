import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("service_comparison",
    Path(__file__).resolve().parents[2] / "scripts" / "compare-index-service.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class ComparisonTests(unittest.TestCase):
    def rows(self):
        return {name: {"workload": name, "hardwareInference": False,
            "os": "fixture", "logicalProcessors": 3, "physicalMemoryBytes": 7,
            "cache": "warm", "modelDelay": "input-bound", "scope": "fixture",
            "trials": [{"trial": number, "vectors": count, "inputs": count,
                "inferenceCalls": count, "syntheticDelayMs": count * 6,
                "wallMs": 1000, "filesPerSecond": count, "completionGapsMs": [1, 2],
                "peakActiveCalls": 3} for number in range(5)]}
            for name, count in [("images", 96), ("documents", 192), ("mixed", 128)]}

    def test_aggregates_all_paired_processes_and_memory_samples(self):
        rows = self.rows()
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "measurements.log"
            with path.open("w", encoding="utf-8") as output:
                for row in rows.values():
                    for trial in row["trials"]:
                        one = {**row, "trials": [trial]}
                        output.write("INDEX_SERVICE_BENCHMARK: " + json.dumps(one) + "\n")
                output.write("123 maximum resident set size\n99 maximum resident set size\n")
            aggregated, memory = comparison.read(path)
        self.assertEqual(memory, [123, 99])
        report = comparison.compare(aggregated, copy.deepcopy(rows))
        self.assertEqual(report["workloads"]["images"]["after"]["trials"], 5)

    def test_different_delay_work_is_rejected_even_when_vectors_match(self):
        before = self.rows()
        after = copy.deepcopy(before)
        after["images"]["trials"][2]["syntheticDelayMs"] += 60
        with self.assertRaisesRegex(ValueError, "different work"):
            comparison.compare(before, after)

    def test_missing_or_duplicate_trials_are_rejected(self):
        for ids in [[0, 1, 2, 3], [0, 1, 2, 3, 3]]:
            after = self.rows()
            after["images"]["trials"] = [{**after["images"]["trials"][0], "trial": number} for number in ids]
            with self.subTest(ids=ids), self.assertRaises(ValueError):
                comparison.compare(self.rows(), after)

    def test_environment_changes_are_rejected(self):
        after = self.rows()
        after["mixed"]["modelDelay"] = "different work"
        with self.assertRaisesRegex(ValueError, "environment"):
            comparison.compare(self.rows(), after)


if __name__ == "__main__":
    unittest.main()
