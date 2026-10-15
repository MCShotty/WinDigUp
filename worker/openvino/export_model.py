#!/usr/bin/env python3
"""Offline preparation, not an application inference path.

Export a local, licensed Transformers EmbeddingGemma 2 snapshot to static OpenVINO graphs. PyTorch runs only here,
to convert and write reference fixtures. Production inference uses digup_openvino.py and exclusively Intel NPU.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from npu_runtime import bundle_id, digest
import numpy as np
import openvino as ov
import torch
from torch import nn


class Tokens(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.embedding = model.language_model.embed_tokens

    def forward(self, input_ids):
        return self.embedding(input_ids)


class Text(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model.language_model

    def forward(self, inputs_embeds, attention_mask):
        # Explicit static masks avoid tracing Transformers' dynamic Python mask factory. Mask arithmetic is in IR.
        length = inputs_embeds.shape[1]
        positions = torch.arange(length, device=inputs_embeds.device)
        valid = attention_mask[:, None, None, :].bool()
        zero = torch.zeros((), dtype=inputs_embeds.dtype, device=inputs_embeds.device)
        negative = torch.full((), torch.finfo(inputs_embeds.dtype).min, dtype=inputs_embeds.dtype, device=inputs_embeds.device)
        full = torch.where(valid.expand(-1, 1, length, -1), zero, negative)
        sliding = (positions[:, None] - positions[None, :]).abs() <= self.model.config.sliding_window
        masks = {"full_attention": full, "sliding_attention": torch.where(valid & sliding[None, None], zero, negative)}
        rows = self.model(inputs_embeds=inputs_embeds, attention_mask=masks,
                          position_ids=positions[None], return_dict=True).last_hidden_state
        weights = attention_mask.to(rows.dtype).unsqueeze(-1)
        pooled = (rows * weights).sum(1) / weights.sum(1).clamp_min(1)
        return torch.nn.functional.normalize(pooled, p=2, dim=-1, eps=1e-12)


class Vision(nn.Module):
    def __init__(self, model, budget: int):
        super().__init__()
        self.tower = model.vision_tower
        self.projection = model.embed_vision
        self.output_length = int(budget)

    def forward(self, pixel_values, pixel_position_ids):
        # Keep padded rows static; stripping them is a host tensor copy after NPU inference.
        padding = (pixel_position_ids == -1).all(dim=-1)
        inputs = self.tower.patch_embedder(pixel_values, pixel_position_ids, padding)
        length = pixel_values.shape[1]
        zero = torch.zeros((), dtype=inputs.dtype, device=inputs.device)
        negative = torch.full((), torch.finfo(inputs.dtype).min, dtype=inputs.dtype, device=inputs.device)
        attention = torch.where((~padding)[:, None, None, :].expand(-1, 1, length, -1), zero, negative)
        rows = self.tower.encoder(inputs_embeds=inputs, attention_mask=attention,
            pixel_position_ids=pixel_position_ids, return_dict=True).last_hidden_state
        rows, valid = self.tower.pooler(rows, pixel_position_ids, padding, self.output_length)
        if self.tower.config.standardize:
            rows = (rows - self.tower.std_bias.float()) * self.tower.std_scale.float()
        return self.projection(rows.to(inputs.dtype)), valid


class Audio(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.tower = model.audio_tower
        self.projection = model.embed_audio

    def forward(self, input_features, input_features_mask):
        rows, valid = self.tower.subsample_conv_projection(input_features, input_features_mask)
        positions = torch.arange(rows.shape[1], device=rows.device)
        distance = positions[:, None] - positions[None, :]
        left = (distance >= 0) & (distance < self.tower.config.attention_context_left - 1)
        right = (distance < 0) & (-distance < self.tower.config.attention_context_right)
        attention = valid[:, None, None, :] & (left | right)[None, None]
        attention = self.tower._convert_4d_mask_to_blocked_5d(attention)
        position_embeddings = self.tower.rel_pos_enc(rows)
        for layer in self.tower.layers:
            rows = layer(rows, attention_mask=attention, position_embeddings=position_embeddings)
        return self.projection(self.tower.output_proj(rows)), valid


def export_graph(module, example: dict[str, torch.Tensor], folder: Path, name: str) -> dict:
    module.eval()
    values = tuple(example.values())
    with torch.inference_mode():
        reference = module(*values)
        if isinstance(reference, torch.Tensor):
            reference = (reference,)
        if not all(torch.isfinite(result).all() for result in reference):
            raise ValueError(f"Source model returned invalid reference data for {name}")
        converted = ov.convert_model(module, example_input=values, input=[
            (key, list(value.shape)) for key, value in example.items()])
    for output, tensor in zip(converted.outputs, reference, strict=True):
        if tuple(output.get_shape()) != tuple(tensor.shape):
            raise ValueError(f"Conversion changed output shape for {name}")
    path = folder / f"{name}.xml"
    ov.save_model(converted, path, compress_to_fp16=False)
    fixture = folder / f"{name}.npz"
    np.savez_compressed(fixture, **{f"input-{key}": value.detach().numpy() for key, value in example.items()},
                        **{f"output-{i}": value.detach().numpy() for i, value in enumerate(reference)})
    return {"file": path.name, "fixture": fixture.name, "inputs": list(example)}


def export_bundle(source: Path, folder: Path, revision: str):
    from PIL import Image
    from transformers import AutoModel, AutoProcessor
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("--revision must be the full Hugging Face snapshot commit")
    if folder.exists() and any(folder.iterdir()):
        raise ValueError("Output folder must be empty; export cannot overwrite a bundle in use")
    folder.mkdir(parents=True, exist_ok=True)
    # No remote code, downloads, quantization or silent precision conversion.
    model = AutoModel.from_pretrained(str(source), local_files_only=True, trust_remote_code=False,
                                     dtype=torch.float32, attn_implementation="eager").eval()
    if model.config.model_type != "embedding_gemma2" or model.config.text_config.embedding_dim != 768:
        raise ValueError("Expected google/embeddinggemma-2, with 768-dimensional output")
    if model.vision_tower is None or model.audio_tower is None:
        raise ValueError("Full EmbeddingGemma 2 snapshot with vision and audio weights required")
    # Audio's custom chunked attention expects a boolean mask (the SDPA mask convention).
    model.audio_tower.config._attn_implementation = "sdpa"
    processor = AutoProcessor.from_pretrained(str(source), local_files_only=True, trust_remote_code=False)
    processor.tokenizer.padding_side = "right"
    processor.save_pretrained(folder / "processor")
    model.config.save_pretrained(folder / "processor")
    graphs = {}
    for role, length in (("query", 512), ("index", 2048)):
        text = "task: search result | query: lemon cake" if role == "query" else "title: recipe.txt | text: Lemon cake recipe."
        encoded = processor.tokenizer(text, padding="max_length", max_length=length, truncation=True, return_tensors="pt")
        ids, mask = encoded["input_ids"], encoded["attention_mask"]
        graphs[f"tokens-{role}"] = export_graph(Tokens(model), {"input_ids": ids}, folder, f"tokens-{role}")
        with torch.inference_mode():
            rows = Tokens(model)(ids)
        graphs[f"text-{role}"] = export_graph(Text(model), {"inputs_embeds": rows, "attention_mask": mask}, folder, f"text-{role}")
    # Rectangular image ensures the fixture tests padding as well as valid image tokens.
    image = Image.fromarray(np.random.default_rng(4).integers(0, 256, (120, 180, 3), dtype=np.uint8))
    for budget in (70, 140, 280, 560, 1120):
        encoded = processor(images=image, images_kwargs={"max_soft_tokens": budget}, return_tensors="pt")
        name = f"vision-{budget}"
        graphs[name] = export_graph(Vision(model, budget), {"pixel_values": encoded["pixel_values"],
            "pixel_position_ids": encoded["image_position_ids"]}, folder, name)
    # Thirty seconds including padded silence, exactly matching runtime feature preparation.
    sound = np.random.default_rng(7).normal(0, 0.1, 16_000).astype(np.float32)
    encoded = processor(audio=sound, sampling_rate=16_000, return_tensors="pt",
                        audio_kwargs={"padding": "max_length", "max_length": 480_000, "truncation": True})
    graphs["audio"] = export_graph(Audio(model), {"input_features": encoded["input_features"],
        "input_features_mask": encoded["input_features_mask"].bool()}, folder, "audio")
    manifest = {"format": 1, "model": "google/embeddinggemma-2", "revision": revision, "dim": 768,
                "lengths": {"query": 512, "index": 2048}, "graphs": graphs,
                "files": {str(path.relative_to(folder).as_posix()): digest(path)
                          for path in sorted(folder.rglob("*")) if path.is_file()}}
    manifest["bundle_id"] = bundle_id(manifest)
    import json
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Exported {folder}. Runtime will verify every stage on the Intel NPU before use.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="Local, complete Transformers model snapshot")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    export_bundle(args.source, args.output, args.revision)
