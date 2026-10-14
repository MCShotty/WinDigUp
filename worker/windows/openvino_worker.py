"""EmbeddingGemma 2's text backbone on OpenVINO NPU, using DigUp's JSON-lines protocol.

The bundle is created by export_openvino.py. Vision/audio towers execute locally on the CPU;
their projected soft tokens, and ordinary text tokens, use the same NPU text backbone.
No automatic device fallback, model downloads, remote code or float16 weight compression.
"""
import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import sys
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("OPENVINO_TELEMETRY_ENABLED", "0")

import numpy as np

DIM = 768
BUDGETS = (70, 140, 280, 560, 1120)


def sha256(path):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(8 << 20), b""):
            result.update(block)
    return result.hexdigest()


def bundle_file(root, name):
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError(f"missing or invalid bundle file: {name}")
    return path


def validate_bundle(root):
    manifest = json.loads((root / "digup-openvino.json").read_text(encoding="utf-8"))
    if (manifest.get("schema") != 1 or manifest.get("model") != "google/embeddinggemma-2"
            or manifest.get("dimension") != DIM or manifest.get("pipeline") != 1
            or manifest.get("precision") != "f32"):
        raise ValueError("not a supported EmbeddingGemma 2 OpenVINO bundle")
    if not manifest.get("revision") or len(manifest.get("probes", [])) < 2:
        raise ValueError("the model revision and reference probes are required")
    files = manifest.get("files", {})
    for name, expected in files.items():
        if sha256(bundle_file(root, name)) != expected:
            raise ValueError(f"bundle checksum failed: {name}; export or copy the bundle again")
    for name, length in (("query", 512), ("index", 2048)):
        graph = manifest["graphs"][name]
        if graph["tokens"] != length or graph["path"] not in files:
            raise ValueError(f"invalid {name} graph")
        if Path(graph["path"]).with_suffix(".bin").as_posix() not in files:
            raise ValueError(f"missing weights for {name}")
    if "token_embeddings.npy" not in files:
        raise ValueError("missing token embedding table")
    if not any(name.startswith("processor/") for name in files):
        raise ValueError("missing local processor")
    fingerprint = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return manifest, fingerprint


def unit_vector(value):
    vector = np.asarray(value, dtype=np.float32)
    if vector.shape != (1, DIM) or not np.isfinite(vector).all():
        raise ValueError("the accelerator produced an invalid or non-finite 768-dimensional vector")
    norm = float(np.linalg.norm(vector))
    if not 0.98 <= norm <= 1.02:
        raise ValueError(f"the accelerator produced an unnormalized vector (norm {norm:.5g})")
    return vector / norm


def check_reference(actual, reference, minimum=0.999):
    actual = unit_vector(actual)
    reference = unit_vector(np.asarray(reference, np.float32).reshape(1, -1))
    cosine = float(np.sum(actual * reference))
    if cosine < minimum:
        raise ValueError(f"device parity failed (cosine {cosine:.6f} < {minimum}); this NPU/driver/precision "
                         "combination cannot safely run these vectors. Choose CPU or GPU instead.")
    return cosine


def model_info(manifest, fingerprint, text_only, device, seconds=0, accelerator=None):
    from importlib.metadata import version
    return {
        "model": manifest["model"], "revision": manifest["revision"],
        "runtime": f"openvino-{version('openvino')}-{device}-pipeline1-{fingerprint[:12]}"
                   f"+transformers-{version('transformers')}+torch-{version('torch')}",
        "dtype": "f32-ir/cpu-media", "dim": DIM, "text_only": text_only,
        "load_seconds": seconds, "accelerator": accelerator or device,
    }


class Embedder:
    def __init__(self, folder, text_only, device="NPU"):
        import openvino as ov

        started = time.perf_counter()
        self.core = ov.Core()
        if not any(item.split(".")[0] == device for item in self.core.available_devices):
            raise RuntimeError(f"OpenVINO device {device} is unavailable; available: {self.core.available_devices}. "
                               "Install Intel's NPU driver. No CPU fallback was used.")
        from transformers import AutoTokenizer
        self.root = Path(folder).resolve()
        self.manifest, fingerprint = validate_bundle(self.root)
        self.text_only = text_only
        self.graph = self.manifest["graphs"]["query" if text_only else "index"]
        self.length = self.graph["tokens"]
        self.tokenizer = AutoTokenizer.from_pretrained(self.root / "processor", local_files_only=True,
                                                      trust_remote_code=False)
        self.table = np.load(self.root / "token_embeddings.npy", mmap_mode="r", allow_pickle=False)
        if self.table.ndim != 2 or self.table.dtype != np.float32:
            raise ValueError("invalid FP32 token embedding table")
        self.scale = float(self.manifest["embedding_scale"])
        self.compiled = self.core.compile_model(str(self.root / self.graph["path"]), device,
                                               {"PERFORMANCE_HINT": "LATENCY"})
        execution = [str(item) for item in self.compiled.get_property("EXECUTION_DEVICES")]
        if not execution or any(item.split(".")[0] != device for item in execution):
            raise RuntimeError(f"requested {device}, but OpenVINO reported {execution}; refusing fallback")
        self.processor = self.media_encoder = None
        # Reference probes are exported from PyTorch, independently of OpenVINO's execution precision.
        for probe in self.manifest["probes"]:
            check_reference(self.text([probe["text"]])[0], probe["vectors"]["query" if text_only else "index"])
        if not text_only:
            self._load_media()
        self.info = model_info(self.manifest, fingerprint, text_only, device, round(time.perf_counter() - started, 2),
                               f"{', '.join(execution)} (text backbone); CPU (vision/audio)")

    def _lookup(self, ids):
        if ids.min() < 0 or ids.max() >= self.table.shape[0]:
            raise ValueError("tokenizer and model vocabulary do not match")
        return np.asarray(self.table[ids], np.float32) * self.scale

    def close(self):
        # Windows locks mapped files until their mappings close. End inference before releasing the
        # table, so a completed session can be removed or replaced without restarting its host.
        self.compiled = None
        self.media_encoder = self.processor = None
        if isinstance(self.table, np.memmap):
            self.table._mmap.close()

    def _infer(self, embeddings, mask):
        count = embeddings.shape[1]
        if count > self.length:
            raise ValueError(f"media input exceeds {self.length} tokens")
        padded = np.zeros((1, self.length, self.table.shape[1]), np.float32)
        padded[:, :count] = embeddings
        attention = np.zeros((1, self.length), np.int64)
        attention[:, :count] = mask
        outputs = self.compiled({"inputs_embeds": padded, "attention_mask": attention})
        return unit_vector(outputs[self.compiled.output("sentence_embedding")])

    def text(self, inputs):
        rows = []
        for text in inputs:
            tokens = self.tokenizer([text], padding=False, truncation=True, max_length=self.length, return_tensors="np")
            ids = np.asarray(tokens["input_ids"], np.int64)
            rows.append(self._infer(self._lookup(ids), tokens["attention_mask"]))
        return (np.concatenate(rows) if rows else np.empty((0, DIM), np.float32)), [None] * len(inputs)

    def _load_media(self):
        import torch
        from safetensors.torch import load_file
        from transformers import AutoConfig, AutoModel, AutoProcessor
        from transformers.models.embedding_gemma2.modeling_embedding_gemma2 import EmbeddingGemma2MultimodalEmbedder

        if "media.safetensors" not in self.manifest["files"]:
            raise RuntimeError("this bundle has no vision/audio encoders; export it without --text-only")
        config = AutoConfig.from_pretrained(self.root / "processor", local_files_only=True, trust_remote_code=False)

        class MediaEncoders(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.vision_tower = AutoModel.from_config(config.vision_config, attn_implementation="eager")
                self.audio_tower = AutoModel.from_config(config.audio_config, attn_implementation="eager")
                self.embed_vision = EmbeddingGemma2MultimodalEmbedder(config.vision_config, config.text_config)
                self.embed_audio = EmbeddingGemma2MultimodalEmbedder(config.audio_config, config.text_config)

        self.media_encoder = MediaEncoders().float().eval()
        self.media_encoder.load_state_dict(load_file(str(self.root / "media.safetensors")), strict=True)
        self.processor = AutoProcessor.from_pretrained(self.root / "processor", local_files_only=True,
                                                       trust_remote_code=False)
        self.config = config

    def media(self, kind, paths, budget=None):
        if self.processor is None:
            raise RuntimeError("this worker was started --text-only")
        if kind == "image" and (budget or 280) not in BUDGETS:
            raise ValueError(f"budget must be one of {BUDGETS}")
        rows, errors = [], []
        for path in paths:
            try:
                if not Path(path).is_file():
                    raise ValueError("media must be an existing local file")
                rows.append(self._media(kind, path, budget or 280))
                errors.append(None)
            except Exception as error:
                rows.append(np.zeros((1, DIM), np.float32))
                errors.append(f"{type(error).__name__}: {error}"[:300])
        return (np.concatenate(rows) if rows else np.empty((0, DIM), np.float32)), errors

    def _media(self, kind, path, budget):
        import torch

        if kind == "image":
            self.processor.image_processor.max_soft_tokens = budget
        inputs = self.processor.apply_chat_template(
            [[{"role": "user", "content": [{"type": kind, "url": path}]}]],
            tokenize=True, return_dict=True, return_tensors="pt")
        ids = inputs["input_ids"].numpy()
        image_mask, audio_mask = ids == self.config.image_token_id, ids == self.config.audio_token_id
        hard_ids = np.where(image_mask | audio_mask, self.config.text_config.pad_token_id, ids)
        embeddings = self._lookup(hard_ids)
        with torch.inference_mode():
            if kind == "image":
                output = self.media_encoder.vision_tower(pixel_values=inputs["pixel_values"],
                    pixel_position_ids=inputs["image_position_ids"], return_dict=True)
                soft = self.media_encoder.embed_vision(output.last_hidden_state).numpy().reshape(-1, self.table.shape[1])
                mask = image_mask
            else:
                output = self.media_encoder.audio_tower(inputs["input_features"], inputs["input_features_mask"], return_dict=True)
                soft = self.media_encoder.embed_audio(output.last_hidden_state)[output.attention_mask.bool()].numpy()
                mask = audio_mask
        if int(mask.sum()) != len(soft):
            raise ValueError("media encoder's soft tokens do not match the processor placeholders")
        embeddings[mask] = soft
        return self._infer(embeddings, inputs["attention_mask"].numpy())


def reply(message):
    print(json.dumps(message, separators=(",", ":"), allow_nan=False), flush=True)


def serve(embedder, stream=sys.stdin):
    for line in stream:
        if not line.strip():
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id, op = request.get("id"), request.get("op")
            if op == "quit":
                reply({"id": request_id, "ok": True})
                break
            if op == "info":
                reply({"id": request_id, "ok": True, "info": embedder.info})
                continue
            inputs = request.get("inputs", [])
            if not isinstance(inputs, list) or any(not isinstance(item, str) for item in inputs):
                raise ValueError("inputs must be an array of strings")
            with contextlib.redirect_stdout(sys.stderr):
                if op == "text":
                    vectors, errors = embedder.text(inputs)
                elif op in ("image", "audio"):
                    vectors, errors = embedder.media(op, inputs, request.get("budget"))
                else:
                    raise ValueError(f"unknown op {op!r}")
            if vectors.shape != (len(inputs), DIM) or len(errors) != len(inputs) or not np.isfinite(vectors).all():
                raise ValueError("invalid vector response")
            reply({"id": request_id, "ok": True, "dim": DIM, "count": len(inputs),
                   "vectors": base64.b64encode(vectors.astype("<f4").tobytes()).decode("ascii"), "errors": errors})
        except Exception as error:
            reply({"id": request_id, "ok": False, "error": f"{type(error).__name__}: {error}"[:500]})


def main():
    # Python's isolated mode ignores PYTHONUTF8. Windows pipe defaults otherwise use the system
    # code page, while Swift's JSONEncoder always writes UTF-8 (including multilingual paths).
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="strict")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--model", required=True, help="local exported OpenVINO bundle")
    parser.add_argument("--text-only", action="store_true")
    parser.add_argument("--metadata", action="store_true", help="report the vector contract without loading an inference model")
    parser.add_argument("--device", choices=("NPU", "CPU"), default="NPU", help="CPU is for export validation only")
    args = parser.parse_args()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            if args.metadata:
                manifest, fingerprint = validate_bundle(Path(args.model).resolve())
                info = model_info(manifest, fingerprint, args.text_only, args.device)
                embedder = None
            else:
                embedder = Embedder(args.model, args.text_only, args.device)
                info = embedder.info
    except Exception as error:
        reply({"ready": False, "error": f"{type(error).__name__}: {error}"[:1000]})
        return 1
    reply({"ready": True, "info": info})
    if embedder is not None:
        try:
            serve(embedder)
        finally:
            embedder.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
