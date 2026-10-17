import base64
import importlib.util
import io
import json
from pathlib import Path
import queue
import struct
import types
import unittest

spec = importlib.util.spec_from_file_location("cuda_reference", Path(__file__).resolve().parents[2] / "scripts" / "check-cuda-reference.py")
protocol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocol)


class WorkerProtocolTests(unittest.TestCase):
    def worker(self, replies):
        worker = protocol.Worker.__new__(protocol.Worker)
        worker.lines = queue.Queue()
        for reply in replies:
            worker.lines.put(None if reply is None else json.dumps(reply))
        worker.timeout = .1
        worker.counter = 0
        worker.process = types.SimpleNamespace(stdin=io.StringIO())
        return worker

    def test_progress_before_ready_is_not_a_ready_reply(self):
        worker = self.worker([{"event": "inference_activity", "phase": "waiting"},
                              {"event": "inference_activity", "phase": "idle"},
                              {"ready": True, "info": {"backend": "nvidia-cuda"}}])
        self.assertTrue(worker.line()["ready"])

    def test_progress_between_vectors_preserves_the_request(self):
        values = [1.0] + [0.0] * 767
        encoded = base64.b64encode(struct.pack("<768f", *values)).decode()
        worker = self.worker([{"event": "inference_activity", "phase": "running"},
                              {"id": 1, "ok": True, "count": 1, "dim": 768, "vectors": encoded}])
        self.assertEqual(worker.embed("text", ["fixture"]), [values])
        self.assertEqual(json.loads(worker.process.stdin.getvalue())["inputs"], ["fixture"])

    def test_crashed_worker_is_reported_after_progress(self):
        worker = self.worker([{"event": "inference_activity"}, None])
        with self.assertRaisesRegex(RuntimeError, "Worker exited"):
            worker.line()

    def test_model_errors_are_not_swallowed(self):
        worker = self.worker([{"id": 1, "ok": False, "error": "unsupported operation"}])
        with self.assertRaisesRegex(RuntimeError, "unsupported operation"):
            worker.embed("text", ["fixture"])


if __name__ == "__main__":
    unittest.main()
