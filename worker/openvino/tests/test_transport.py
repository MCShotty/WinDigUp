"""Verify that media rows pass to the NPU text graph without a host model stage or lost padding mask."""
from pathlib import Path
import sys
from types import SimpleNamespace

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from npu_runtime import NPURuntime


def test_media_placeholders_copy_projected_rows_to_npu_text_input():
    runtime = NPURuntime.__new__(NPURuntime)
    runtime.role = "index"
    runtime.processor = SimpleNamespace(tokenizer=SimpleNamespace(pad_token_id=0))
    ids = np.array([[2, 90, 90, 1, 0]])
    mask = np.array([[1, 1, 1, 1, 0]])
    projected = np.arange(8, dtype=np.float32).reshape(2, 4)
    calls = []
    def infer(name, inputs):
        calls.append(name)
        # Out-of-vocabulary media IDs must be replaced before the accelerator's token lookup.
        np.testing.assert_array_equal(inputs["input_ids"], [[2, 0, 0, 1, 0]])
        return [np.full((1, 5, 4), -3, dtype=np.float32)]
    runtime.run = infer
    result = runtime._text_inputs({"input_ids": ids, "attention_mask": mask}, projected, 90)
    assert calls == ["tokens-index"]
    np.testing.assert_array_equal(result["inputs_embeds"][0, 1:3], projected)
    np.testing.assert_array_equal(result["inputs_embeds"][0, [0, 3, 4]], -3)
    np.testing.assert_array_equal(result["attention_mask"], mask)
    np.testing.assert_array_equal(ids, [[2, 90, 90, 1, 0]])  # processor's data is not modified
    with pytest.raises(ValueError, match="token count"):
        runtime._text_inputs({"input_ids": ids, "attention_mask": mask}, projected[:1], 90)


def test_image_uses_valid_npu_rows_for_non_square_padded_image(tmp_path):
    from PIL import Image
    path = tmp_path / "non-ascii-عربي.png"
    Image.new("RGB", (12, 8)).save(path)
    runtime = NPURuntime.__new__(NPURuntime)
    runtime.text_only = False
    runtime.length = 2048
    calls = []
    class Processor:
        image_token_id = 90
        def __call__(self, **kwargs):
            assert kwargs["images_kwargs"]["max_soft_tokens"] == 70
            return {"input_ids": np.array([[2, 90, 90, 1]]), "pixel_values": np.zeros((1, 630, 768)),
                    "image_position_ids": np.zeros((1, 630, 2), dtype=np.int64)}
    runtime.processor = Processor()
    def infer(name, inputs):
        calls.append(name)
        return [np.array([[[1., 2.], [3., 4.], [99., 99.]]]), np.array([[True, True, False]])]
    runtime.run = infer
    def vector(encoded, features, token_id):
        assert token_id == 90
        np.testing.assert_array_equal(features, [[1., 2.], [3., 4.]])
        return "ok"
    runtime._vector = vector
    assert runtime.image(str(path), 70) == "ok"
    assert calls == ["vision-70"]
