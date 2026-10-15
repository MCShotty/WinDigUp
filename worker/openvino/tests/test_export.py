"""Conversion/parity tests only: CPU evaluates tiny IR fixtures, never the application's inference pipeline."""
from pathlib import Path
import sys

import numpy as np
import openvino as ov
import pytest
import torch
from transformers import EmbeddingGemma2Config, EmbeddingGemma2Model, EmbeddingGemma2TextConfig, Gemma4AudioConfig, Gemma4VisionConfig

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from export_model import Audio, Text, Tokens, Vision, export_graph
from npu_runtime import check_parity


@pytest.fixture(scope="module")
def model():
    torch.manual_seed(4)
    torch.set_num_threads(2)
    config = EmbeddingGemma2Config(
        text_config=EmbeddingGemma2TextConfig(vocab_size=64, hidden_size=16, intermediate_size=32,
            num_hidden_layers=2, num_attention_heads=2, num_key_value_heads=1, head_dim=8, global_head_dim=8,
            hidden_size_per_layer_input=8, embedding_dim=768, sliding_window=4,
            layer_types=["sliding_attention", "full_attention"]),
        vision_config=Gemma4VisionConfig(hidden_size=16, intermediate_size=32, num_hidden_layers=1,
            num_attention_heads=2, num_key_value_heads=2, head_dim=8, patch_size=2, pooling_kernel_size=2,
            position_embedding_size=32),
        audio_config=Gemma4AudioConfig(hidden_size=16, num_hidden_layers=1, num_attention_heads=2,
            subsampling_conv_channels=[8, 2], output_proj_dims=16, use_clipped_linears=False,
            attention_chunk_size=4, attention_context_left=1, attention_context_right=0),
    )
    config._attn_implementation = "eager"
    result = EmbeddingGemma2Model(config).eval()
    result.audio_tower.config._attn_implementation = "sdpa"
    return result


def verify_ir(module, inputs, tmp_path, name):
    entry = export_graph(module, inputs, tmp_path, name)
    # This is a test of the exported graph's mathematics, explicitly separate from NPURuntime.
    compiled = ov.Core().compile_model(str(tmp_path / entry["file"]), "CPU", {"INFERENCE_PRECISION_HINT": "f32"})
    with np.load(tmp_path / entry["fixture"], allow_pickle=False) as fixture:
        feed = {key: fixture[f"input-{key}"] for key in inputs}
        actual = compiled(feed)
        for i, output in enumerate(compiled.outputs):
            check_parity(actual[output], fixture[f"output-{i}"], name)
    # A second input guards against a trace accidentally baking sample values or padding into the graph.
    varied = {key: value.clone() for key, value in inputs.items()}
    for key, value in varied.items():
        if key in ("pixel_values", "input_features", "inputs_embeds"):
            value.mul_(0.3).add_(0.1)
        elif key == "input_ids":
            value[:, 1:4] = torch.tensor([12, 7, 6])
        elif key in ("attention_mask", "input_features_mask"):
            value[:, value.shape[1] // 2:] = 0
    with torch.inference_mode():
        reference = module(*varied.values())
        if isinstance(reference, torch.Tensor):
            reference = (reference,)
    actual = compiled({key: value.numpy() for key, value in varied.items()})
    for output, expected in zip(compiled.outputs, reference, strict=True):
        check_parity(actual[output], expected.numpy(), name + "/second-input")


def test_text_projection_pooling_normalization_match_source(model, tmp_path):
    ids = torch.tensor([[2, 4, 8, 10, 11, 5, 1, 0]])
    mask = (ids != 0).long()
    with torch.inference_mode():
        rows = Tokens(model)(ids)
        original = model.language_model(input_ids=ids, attention_mask=mask).last_hidden_state
        expected = torch.nn.functional.normalize((original * mask[..., None]).sum(1) / mask.sum(1, keepdim=True), dim=-1)
        actual = Text(model)(rows, mask)
        torch.testing.assert_close(actual, expected, rtol=1e-4, atol=1e-5)
    verify_ir(Tokens(model), {"input_ids": ids}, tmp_path, "tokens")
    verify_ir(Text(model), {"inputs_embeds": rows, "attention_mask": mask}, tmp_path, "text")


def test_vision_encoder_and_projection_ir(model, tmp_path):
    pixels = torch.randn(1, 16, 12)
    positions = torch.tensor([[[x, y] for y in range(4) for x in range(4)]])
    positions[:, 12:] = -1
    with torch.inference_mode():
        rows, mask = Vision(model, 4)(pixels, positions)
        expected = model.embed_vision(model.vision_tower(pixel_values=pixels, pixel_position_ids=positions).last_hidden_state)
        torch.testing.assert_close(rows[mask], expected)
    verify_ir(Vision(model, 4), {"pixel_values": pixels, "pixel_position_ids": positions}, tmp_path, "vision")


def test_audio_encoder_and_projection_ir(model, tmp_path):
    features = torch.randn(1, 32, 8)
    mask = torch.ones(1, 32, dtype=torch.bool)
    mask[:, 20:] = False
    with torch.inference_mode():
        rows, valid = Audio(model)(features, mask)
        original = model.audio_tower(input_features=features, attention_mask=mask)
        torch.testing.assert_close(rows, model.embed_audio(original.last_hidden_state))
        torch.testing.assert_close(valid, original.attention_mask)
    verify_ir(Audio(model), {"input_features": features, "input_features_mask": mask}, tmp_path, "audio")
