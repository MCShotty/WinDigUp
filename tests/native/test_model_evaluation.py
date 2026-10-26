import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import model_evaluation as contract

spec = importlib.util.spec_from_file_location("embedding_model_runner",
    Path(__file__).resolve().parents[2] / "scripts" / "evaluate-embedding-model.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ModelEvaluationTests(unittest.TestCase):
    def receipt(self):
        return {"model": "fixture-model", "revision": "fixture-revision", "runtime": "fixture-runtime",
                "dtype": "fixture-precision", "dim": 3, "backend": "amd-vulkan", "device_id": "fixture-gpu",
                "execution_policy": "accelerator-only"}

    def report(self):
        rows = []
        for modality in contract.MODALITIES:
            for index in range(15):
                positive = index < 10
                rows.append({"id": modality + str(index), "modality": modality,
                    "language": "en" if index % 3 == 0 else "ar" if index % 3 == 1 else "bn",
                    "querySHA256": contract.digest([modality, index]), "expected": ["relevant"] if positive else [],
                    "ranked": ["irrelevant", "relevant"] if positive else ["irrelevant"],
                    "matches": ["relevant"] if positive else [], "milliseconds": 20})
        return {"schemaVersion": 1, "kind": "model-retrieval-evaluation", "completed": True,
                "receipt": self.receipt(), "queryReceipt": self.receipt(), "backend": "amd-vulkan", "deviceID": "fixture-gpu",
                "corpusSHA256": "fixture-corpus-hash", "helperSHA256": "fixture-helper-hash",
                "modelFiles": {"fixture.bin": "fixture-hash"}, "machine": {"referenceID": "fixture-host"},
                "scope": "fixture", "policy": {"threshold": .6}, "corpusOrigin": "synthetic", "corpusSplit": "test",
                "documentTrials": [{"trial": i, "documents": 20, "elapsedMs": 200} for i in range(5)],
                "coldFullMs": 10, "coldQueryMs": 10, "queries": rows}

    def candidate(self):
        report = self.report()
        report["receipt"]["model"] = "candidate-fixture"
        report["queryReceipt"]["model"] = "candidate-fixture"
        for row in report["queries"]:
            row["milliseconds"] = 10
            if row["expected"]:
                row["ranked"] = ["relevant"]
        for row in report["documentTrials"]:
            row["elapsedMs"] = 100
        return report

    def test_favorable_fixture_never_becomes_physical_or_adopted(self):
        before, after = self.report(), self.candidate()
        for row in before["queries"]:
            if row["expected"] and row["id"].endswith("0"):
                row["ranked"] = ["irrelevant"]
                row["matches"] = []
        result = contract.compare(before, after)
        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(result["recommendation"], "keep-baseline")
        self.assertFalse(result["productionModelChanged"])
        self.assertTrue(any("held-out" in x for x in result["missingGates"]))
        self.assertTrue(any("full-indexing" in x for x in result["missingGates"]))
        self.assertNotIn("physicalValidated", result)

    def test_same_profile_is_not_a_model_comparison(self):
        result = contract.compare(self.report(), self.report())
        self.assertTrue(any("same model/profile" in x for x in result["missingGates"]))

    def test_slower_query_or_document_encoding_is_rejected(self):
        for mode in ("query", "document"):
            before, after = self.report(), self.candidate()
            if mode == "query":
                for row in after["queries"]:
                    row["milliseconds"] = 30
            else:
                for row in after["documentTrials"]:
                    row["elapsedMs"] = 300
            with self.subTest(mode=mode):
                result = contract.compare(before, after)
                self.assertEqual(result["status"], "rejected")
                self.assertTrue(any("not faster" in x for x in result["failures"]))

    def test_device_corpus_machine_or_policy_changes_are_not_comparable(self):
        for key, value in (("corpusSHA256", "changed"), ("deviceID", "other-gpu"),
                           ("machine", {"referenceID": "other-host"}), ("policy", {"threshold": .8})):
            before, after = self.report(), self.candidate()
            after[key] = value
            if key == "deviceID":
                after["receipt"]["device_id"] = value
                after["queryReceipt"]["device_id"] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "comparable"):
                contract.compare(before, after)

    def test_changed_judgments_and_duplicate_queries_are_rejected(self):
        after = self.candidate()
        after["queries"][0]["expected"] = []
        with self.assertRaisesRegex(ValueError, "judgments"):
            contract.compare(self.report(), after)
        after = self.candidate()
        after["queries"].append(copy.deepcopy(after["queries"][0]))
        with self.assertRaisesRegex(ValueError, "unique"):
            contract.compare(self.report(), after)

    def test_missing_modality_samples_or_numerical_evidence_remain_incomplete(self):
        before, after = self.report(), self.candidate()
        for report in (before, after):
            report["queries"] = [x for x in report["queries"] if x["modality"] != "audio"]
            report["documentTrials"] = report["documentTrials"][:3]
        result = contract.compare(before, after)
        self.assertTrue(any("audio" in x for x in result["missingGates"]))
        self.assertTrue(any("five" in x for x in result["missingGates"]))
        self.assertTrue(any("numerical" in x for x in result["missingGates"]))

    def test_unequal_completed_document_work_is_rejected(self):
        after = self.candidate()
        after["documentTrials"][2]["documents"] += 1
        with self.assertRaisesRegex(ValueError, "different work"):
            contract.compare(self.report(), after)

    def test_negative_false_positives_and_language_regression_are_rejected(self):
        before, after = self.report(), self.candidate()
        for row in after["queries"]:
            if not row["expected"]:
                row["matches"] = ["irrelevant"]
            if row["language"] == "ar" and row["expected"]:
                row["ranked"] = row["matches"] = []
        result = contract.compare(before, after)
        self.assertTrue(any("false positives" in x for x in result["failures"]))
        self.assertTrue(any("byLanguage/ar" in x for x in result["failures"]))

    def test_receipts_reject_cpu_wrong_adapter_and_unsafe_cuda(self):
        for change, backend, device in (
            ({"execution_policy": "cpu"}, "amd-vulkan", "fixture-gpu"),
            ({"device_id": "other"}, "amd-vulkan", "fixture-gpu"),
            ({"backend": "nvidia-cuda"}, "nvidia-cuda", "fixture-gpu"),
            ({"backend": "openvino-npu", "device": "CPU"}, "openvino-npu", "")):
            with self.subTest(change=change), self.assertRaises(ValueError):
                contract.validate_receipt({**self.receipt(), **change}, backend, device)

    def test_metrics_distinguish_query_hit_from_document_recall(self):
        rows = [{"expected": ["a", "b"], "ranked": ["a"], "matches": ["a"]},
                {"expected": [], "ranked": ["c"], "matches": []}]
        result = contract.query_metrics(rows)
        self.assertEqual(result["hitAt3"], 1)
        self.assertEqual(result["recallAt10"], .5)
        self.assertEqual(result["negativeFalsePositiveRate"], 0)

    def test_nonnumeric_and_unnormalized_vectors_are_rejected(self):
        for values in ([float("nan"), 0, 0], [2, 0, 0], [True, 0, 0], [1, 0]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                contract.validate_vector(values, 3)

    def test_json_duplicates_and_nonfinite_values_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "report.json"
            for text in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}'):
                path.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    contract.load_json(path)

    def test_media_hash_and_symlink_changes_fail_before_inference(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            path = root / "image.png"
            path.write_bytes(b"fixture")
            document = {"id": "image", "operation": "image", "input": "image.png",
                        "sha256": contract.file_digest(path)}
            self.assertEqual(runner.frame_document(document, root), str(path))
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "changed"):
                runner.frame_document(document, root)

    def test_corpus_requires_unique_ids_and_explicit_origins(self):
        corpus = {"schemaVersion": 1, "origin": "synthetic", "split": "test",
                  "documents": [{"id": "doc", "modality": "text", "operation": "text", "input": "fixture", "language": "en"}],
                  "queries": [{"id": "q", "q": "fixture", "modality": "text", "language": "en", "expected": ["doc"]}]}
        contract.validate_corpus(corpus)
        for change in ("origin", "document", "query"):
            altered = copy.deepcopy(corpus)
            if change == "origin":
                altered.pop("origin")
            elif change == "document":
                altered["documents"].append(copy.deepcopy(altered["documents"][0]))
            else:
                altered["queries"][0]["expected"] = ["missing"]
            with self.subTest(change=change), self.assertRaises(ValueError):
                contract.validate_corpus(altered)

    def test_audio_label_cannot_be_satisfied_by_text(self):
        corpus = {"schemaVersion": 1, "origin": "synthetic", "split": "test",
            "documents": [{"id": "audio", "modality": "audio", "operation": "text", "input": "speech", "language": "en"}],
            "queries": [{"id": "q", "q": "speech", "modality": "audio", "language": "en", "expected": ["audio"]}]}
        with self.assertRaisesRegex(ValueError, "declared modality"):
            contract.validate_corpus(corpus)

    def test_changed_model_artifacts_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            model = root / "model.bin"
            model.write_bytes(b"before")
            expected = {"model.bin": contract.file_digest(model)}
            runner.verify_inputs([], root, root, expected)
            model.write_bytes(b"after")
            with self.assertRaisesRegex(ValueError, "changed"):
                runner.verify_inputs([], root, root, expected)

    def test_collector_uses_real_scopes_and_marks_synthetic_corpus(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        info = self.receipt()
        class FakeWorker:
            def __init__(self, *args):
                self.info = info
                self.identity = contract.validate_receipt(info, "amd-vulkan", "fixture-gpu")
                self.cold_ms = 1
            def embed(self, operation, value, budget=None):
                return [1, 0, 0]
            def close(self):
                pass
        corpus = {"schemaVersion": 1, "origin": "synthetic", "split": "test",
            "documents": [
                {"id": "app", "modality": "application", "language": "en", "operation": "text", "input": "app"},
                {"id": "file", "modality": "text", "language": "en", "operation": "text", "input": "file"}],
            "queries": [
                {"id": "app-q", "q": "app", "modality": "application", "language": "en", "expected": ["app"]},
                {"id": "file-q", "q": "file", "modality": "text", "language": "en", "expected": ["file"]}]}
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            models = root / "models"
            models.mkdir()
            (models / "weights.bin").write_bytes(b"fake-test-weights")
            manifest = root / "corpus.json"
            manifest.write_text(json.dumps(corpus))
            args = SimpleNamespace(corpus=manifest, prompt_profile=None, output=root / "output",
                models=models, helper=Path(sys.executable), backend="amd-vulkan", device="fixture-gpu",
                machine_id="fixture-host", timeout=1, trials=5, minimum_cosine=.6, distance_from_best=.08)
            with patch.object(runner, "Worker", FakeWorker):
                report = runner.collect(args)
            self.assertEqual(report["corpusOrigin"], "synthetic")
            self.assertEqual([row["ranked"] for row in report["queries"]], [["app"], ["file"]])
            self.assertEqual(len(report["documentTrials"]), 5)
            self.assertTrue((args.output / "model-evaluation.json").is_file())
            self.assertNotIn("physicalValidated", report)

    def test_candidate_inventory_and_smoke_corpus_are_not_adoption_claims(self):
        root = Path(__file__).resolve().parents[2]
        contract.validate_corpus(contract.load_json(root / "evals/model-evaluation.example.json"))
        inventory = contract.load_json(root / "evals/model-candidates.json")
        self.assertFalse(inventory["productionSelectionChanged"])
        qwen = next(row for row in inventory["models"] if row["id"] == "Qwen/Qwen3-VL-Embedding-2B")
        self.assertNotIn("audio", qwen["modalities"])
        self.assertIn("blocked", qwen["adoptionStatus"])

    def test_prompt_profile_is_explicit_and_code_prompt_matches_production(self):
        self.assertIn("code retrieval", runner.DEFAULT_PROMPTS["codeQuery"])
        self.assertEqual(runner.prompt(runner.DEFAULT_PROMPTS["document"], "body", "title"),
                         "title: title | text: body")
        for text in ("{text.__class__}", "{text}{text}", "{title}"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                runner.validate_prompts({**runner.DEFAULT_PROMPTS, "query": text})

    def test_worker_progress_and_deadlines_are_bounded(self):
        import queue
        worker = runner.Worker.__new__(runner.Worker)
        worker.lines = queue.Queue()
        worker.timeout = .01
        worker.lines.put('{"event":"inference_activity"}')
        worker.lines.put('{"ready":true}')
        self.assertTrue(worker.line()["ready"])
        with self.assertRaises(TimeoutError):
            worker.line()
        worker.lines.put(None)
        with self.assertRaisesRegex(RuntimeError, "exited"):
            worker.line()

    def test_query_receipt_cannot_change_model_or_dimension(self):
        report = self.report()
        report["queryReceipt"]["dim"] += 1
        with self.assertRaisesRegex(ValueError, "identities"):
            contract.valid_report(report)

    def test_comparison_cli_preserves_existing_evidence(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            for name, report in (("before", self.report()), ("after", self.candidate())):
                (root / (name + ".json")).write_text(json.dumps(report))
            output = root / "comparison.json"
            output.write_text("keep me")
            process = subprocess.run([sys.executable, str(Path(contract.__file__).with_name("compare-model-evaluations.py")),
                str(root / "before.json"), str(root / "after.json"), "--output", str(output)],
                capture_output=True, text=True, timeout=10)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(output.read_text(), "keep me")


if __name__ == "__main__":
    unittest.main()
