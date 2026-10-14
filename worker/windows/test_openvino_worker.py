import base64
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
import openvino as ov
from openvino import opset13 as ops
import pytest

spec = importlib.util.spec_from_file_location("openvino_worker", Path(__file__).with_name("openvino_worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
sys.modules["openvino_worker"] = worker


def test_openvino_actual_cpu_pool_and_normalize():
    embeddings = ops.parameter([1, 4, 768], np.float32, name="embeddings")
    mask = ops.parameter([1, 4, 1], np.float32, name="mask")
    pooled = ops.reduce_sum(ops.multiply(embeddings, mask), ops.constant([1]), False)
    norm = ops.sqrt(ops.reduce_sum(ops.multiply(pooled, pooled), ops.constant([1]), True))
    model = ov.Model([ops.divide(pooled, norm)], [embeddings, mask])
    compiled = ov.Core().compile_model(model, "CPU", {"INFERENCE_PRECISION_HINT": "f32"})
    rng = np.random.default_rng(7)
    values = rng.normal(size=(1, 4, 768)).astype(np.float32)
    weights = np.array([1, 1, 0, 0], np.float32).reshape(1, 4, 1)
    result = compiled([values, weights])[compiled.output(0)]
    expected = values[:, :2].sum(1)
    expected /= np.linalg.norm(expected)
    assert worker.check_reference(result, expected) >= 0.99999
    assert compiled.get_property("EXECUTION_DEVICES") == ["CPU"]


@pytest.mark.parametrize("value", [np.zeros((1, 768)), np.full((1, 768), np.nan), np.ones((1, 767))])
def test_invalid_device_output_rejected(value):
    with pytest.raises(ValueError):
        worker.unit_vector(value)


def test_low_parity_rejected():
    first = np.zeros((1, 768), np.float32)
    second = first.copy()
    first[0, 0], second[0, 1] = 1, 1
    with pytest.raises(ValueError, match="parity"):
        worker.check_reference(first, second)


def test_manifest_tamper_and_path_escape(tmp_path):
    asset = tmp_path / "weights.bin"
    asset.write_bytes(b"original")
    manifest = {"schema": 1, "model": "google/embeddinggemma-2", "dimension": 768, "pipeline": 1,
                "precision": "f32", "revision": "1234567", "probes": [{}, {}],
                "files": {"weights.bin": worker.sha256(asset)}}
    (tmp_path / "digup-openvino.json").write_text(json.dumps(manifest))
    asset.write_bytes(b"changed")
    with pytest.raises(ValueError, match="checksum"):
        worker.validate_bundle(tmp_path)
    with pytest.raises(ValueError, match="invalid"):
        worker.bundle_file(tmp_path, "../outside.bin")


def test_protocol_matches_swift_little_endian_contract(capsys):
    class FakeEmbedder:
        info = {"dim": 768}
        def text(self, inputs):
            return np.tile(np.arange(768, dtype=np.float32), (len(inputs), 1)), [None] * len(inputs)
    worker.serve(FakeEmbedder(), io.StringIO('{"id":7,"op":"text","inputs":["العربية","বাংলা"]}\n'
                                          '{"id":8,"op":"text","inputs":[]}\n'
                                          '{"id":9,"op":"quit"}\n'))
    replies = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert replies[0]["id"] == 7 and replies[0]["count"] == 2
    decoded = np.frombuffer(base64.b64decode(replies[0]["vectors"]), dtype="<f4").reshape(2, 768)
    np.testing.assert_equal(decoded[0], np.arange(768, dtype=np.float32))
    assert replies[1]["count"] == 0 and replies[1]["vectors"] == ""
    assert replies[2] == {"id": 9, "ok": True}


def test_bad_request_does_not_break_next_request(capsys):
    class FakeEmbedder:
        info = {"dim": 768}
    worker.serve(FakeEmbedder(), io.StringIO('{"id":1,"op":"text","inputs":[42]}\n'
                                          '{"id":2,"op":"info"}\n'))
    replies = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert replies[0]["ok"] is False and replies[1]["info"]["dim"] == 768


def test_no_npu_never_claims_ready(tmp_path):
    if "NPU" in ov.Core().available_devices:
        pytest.skip("needs a host without NPU")
    result = subprocess.run([sys.executable, "-I", str(Path(__file__).with_name("openvino_worker.py")),
                             "--model", str(tmp_path), "--device", "NPU"], capture_output=True, text=True, timeout=30)
    message = json.loads(result.stdout)
    assert result.returncode != 0 and message["ready"] is False
    assert "unavailable" in message["error"] and "No CPU fallback" in message["error"]


def test_export_real_embeddinggemma2_architecture_and_worker(tmp_path):
    # A small random checkpoint exercises the actual Transformers architecture and conversion,
    # without downloading Google's weights or pretending to validate their NPU performance.
    torch = pytest.importorskip("torch")
    transformers = pytest.importorskip("transformers")
    from tokenizers import Tokenizer
    from tokenizers.models import WordLevel
    from tokenizers.pre_tokenizers import Whitespace
    from tokenizers.processors import TemplateProcessing
    export_spec = importlib.util.spec_from_file_location("export_openvino", Path(__file__).with_name("export_openvino.py"))
    exporter = importlib.util.module_from_spec(export_spec)
    export_spec.loader.exec_module(exporter)
    source, output = tmp_path / "source", tmp_path / "exported"
    text = transformers.EmbeddingGemma2TextConfig(vocab_size=8, hidden_size=16, intermediate_size=32,
        num_hidden_layers=2, num_attention_heads=2, num_key_value_heads=1, head_dim=8,
        hidden_size_per_layer_input=4, embedding_dim=768, layer_types=["sliding_attention", "full_attention"],
        sliding_window=4, per_layer_config={})
    config = transformers.EmbeddingGemma2Config(text_config=text.to_dict(), vision_config=None, audio_config=None)
    torch.manual_seed(7)
    transformers.AutoModel.from_config(config, attn_implementation="eager").eval().save_pretrained(source)
    tokenizer = Tokenizer(WordLevel({"<pad>": 0, "<eos>": 1, "<bos>": 2, "<unk>": 3,
                                    "task": 4, "query": 5, "text": 6, "archive": 7}, unk_token="<unk>"))
    tokenizer.pre_tokenizer = Whitespace()
    tokenizer.post_processor = TemplateProcessing(single="<bos> $A <eos>", special_tokens=[("<bos>", 2), ("<eos>", 1)])
    transformers.PreTrainedTokenizerFast(tokenizer_object=tokenizer, pad_token="<pad>", bos_token="<bos>",
        eos_token="<eos>", unk_token="<unk>").save_pretrained(source)
    exporter.export(source, output, "tiny-fixture-1", text_only=True, verify_device="CPU")
    embedder = worker.Embedder(output, text_only=True, device="CPU")
    rows, errors = embedder.text(["task: search result | query: archive"])
    assert rows.shape == (1, 768) and errors == [None]
    assert embedder.info["accelerator"].startswith("CPU")
    worker.unit_vector(rows)
    manifest, fingerprint = worker.validate_bundle(output)
    # Metadata and a live encoder must agree, even though text-only does not load media encoders.
    assert worker.model_info(manifest, fingerprint, True, "CPU")["runtime"] == embedder.info["runtime"]
    embedder.close()
    (output / "token_embeddings.npy").write_bytes(b"corrupted")
    with pytest.raises(ValueError, match="checksum"):
        worker.validate_bundle(output)
