"""All neural-network stages run on the explicitly selected Intel accelerator. NumPy only transports tensors and checks results.

The tokenizer, image decoder/resizer and audio feature extractor are host preprocessing. No PyTorch model is
loaded by this module. AUTO, HETERO, CPU and software inference are deliberately unavailable.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re

import numpy as np
from devices import compile_gpu, device_aliases, select_device, verify_selected


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def bundle_id(manifest: dict) -> str:
    return hashlib.sha256(json.dumps({k: v for k, v in manifest.items() if k != "bundle_id"},
                                     sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def only_npu(devices) -> bool:
    return bool(devices) and all(re.fullmatch(r"NPU(?:\.\d+)?", str(d)) for d in devices)


def verify_execution(compiled) -> None:
    devices = compiled.get_property("EXECUTION_DEVICES")
    if not only_npu(devices):
        raise RuntimeError(f"Exclusive Intel NPU execution required, got {devices!r}; CPU fallback disabled")


def compile_npu(core, model, name: str, device="NPU"):
    # NPUW can partition an explicit NPU request between NPU and CPU. Do not enable that wrapper.
    supported = core.query_model(model, device, {"NPU_USE_NPUW": False})
    allowed_ops = device_aliases(device, "NPU") | {"NPU"}
    unsupported = {op.get_type_name() for op in model.get_ops()
        if op.get_type_name() not in ("Parameter", "Result", "Constant")
        and str(supported.get(op.get_friendly_name(), "")) not in allowed_ops}
    if unsupported:
        raise RuntimeError(f"NPU does not support {name}: {', '.join(sorted(unsupported))}; CPU fallback disabled")
    compiled = core.compile_model(model, device, {"PERFORMANCE_HINT": "LATENCY", "ENABLE_PROFILING": True,
                                               "NPU_USE_NPUW": False})
    verify_execution(compiled)
    return compiled


def validate_bundle(folder: Path) -> dict:
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("format") != 1 or manifest.get("model") != "google/embeddinggemma-2":
        raise ValueError("Expected a DigUp EmbeddingGemma 2 OpenVINO bundle, format 1")
    if manifest.get("bundle_id") != bundle_id(manifest):
        raise ValueError("Model manifest fingerprint is invalid; export the bundle again")
    if manifest.get("dim") != 768:
        raise ValueError("EmbeddingGemma 2 output must have 768 dimensions")
    for name, expected in manifest["files"].items():
        path = (folder / name).resolve()
        if not path.is_relative_to(folder.resolve()) or not path.is_file() or digest(path) != expected:
            raise ValueError(f"Missing or changed bundle file: {name}")
    required = {"tokens-query", "tokens-index", "text-query", "text-index", "audio"}
    required.update(f"vision-{budget}" for budget in (70, 140, 280, 560, 1120))
    if not required.issubset(manifest["graphs"]):
        raise ValueError("Bundle must contain text, vision and audio graphs, including all image budgets")
    for entry in manifest["graphs"].values():
        for name in (entry["file"], str(Path(entry["file"]).with_suffix(".bin")), entry["fixture"]):
            if name not in manifest["files"]:
                raise ValueError(f"Unverified graph or fixture: {name}")
    return manifest


def check_parity(actual, reference, name: str, device="NPU") -> None:
    a, b = np.asarray(actual), np.asarray(reference)
    if a.shape != b.shape or not np.isfinite(a).all():
        raise RuntimeError(f"{device} parity failed for {name}: invalid shape or non-finite values")
    if a.dtype == np.bool_ or b.dtype == np.bool_:
        if not np.array_equal(a, b):
            raise RuntimeError(f"{device} parity failed for {name}: different mask")
        return
    a, b = a.astype(np.float64).ravel(), b.astype(np.float64).ravel()
    norm_a, norm_b = np.linalg.norm(a), np.linalg.norm(b)
    if not norm_b:
        valid = np.allclose(a, b, atol=1e-5)
    else:
        cosine = np.dot(a, b) / (norm_a * norm_b) if norm_a else 0
        valid = cosine >= 0.999 and np.linalg.norm(a - b) / norm_b <= 0.02
    if not valid:
        raise RuntimeError(f"{device} parity failed for {name}; this model/driver cannot run accurately without CPU fallback")


class NPURuntime:
    def __init__(self, folder: str | Path, text_only: bool = False, *, core=None,
                 backend="openvino-npu", device="", cache=None):
        if core is None:
            import openvino as ov
            core = ov.Core()
        self.backend = backend
        if backend == "openvino-npu" and not any(only_npu([item]) for item in core.available_devices):
            raise RuntimeError("Intel NPU not found. Install the Intel NPU driver; CPU fallback is disabled")
        self.selected = select_device(core, backend, device)
        if cache:
            cache = Path(cache).resolve()
            cache.mkdir(parents=True, exist_ok=True)
            core.set_property({"CACHE_DIR": str(cache)})
        self.folder = Path(folder).resolve()
        self.manifest = validate_bundle(self.folder)
        self.text_only = text_only
        self.graphs = {}
        role = "query" if text_only else "index"
        names = [f"tokens-{role}", f"text-{role}"]
        if not text_only:
            names += [f"vision-{budget}" for budget in (70, 140, 280, 560, 1120)] + ["audio"]
        # Compile and verify every required stage before advertising readiness. No partial NPU/CPU pipeline.
        for name in names:
            entry = self.manifest["graphs"][name]
            model = core.read_model(str(self.folder / entry["file"]))
            compiled = (compile_npu(core, model, name, self.selected["id"]) if backend == "openvino-npu"
                        else compile_gpu(core, model, name, self.selected))
            verify_selected(compiled, self.selected)
            self.graphs[name] = compiled.create_infer_request()
            with np.load(self.folder / entry["fixture"], allow_pickle=False) as fixture:
                inputs = {key: fixture[f"input-{key}"] for key in entry["inputs"]}
                results = self.run(name, inputs)
                for i, result in enumerate(results):
                    check_parity(result, fixture[f"output-{i}"], f"{name}/{i}", self.selected["id"])
        from transformers import AutoProcessor
        self.processor = AutoProcessor.from_pretrained(str(self.folder / "processor"), local_files_only=True,
                                                       trust_remote_code=False)
        self.processor.tokenizer.padding_side = "right"
        self.role = role
        self.length = self.manifest["lengths"][role]

    def run(self, name: str, inputs: dict) -> list[np.ndarray]:
        request = self.graphs[name]
        # Explicit NPU compilation is checked again for each request, including cached compiled models.
        verify_selected(request.get_compiled_model(), self.selected)
        result = request.infer(inputs)
        for item in request.profiling_info:
            if "CPU" in item.exec_type.upper():
                raise RuntimeError(f"CPU execution reported for {name}/{item.node_name}; inference rejected")
        return [np.array(result[output], copy=True) for output in request.get_compiled_model().outputs]

    def _text_inputs(self, encoded: dict, features=None, token_id=None) -> dict:
        ids = np.asarray(encoded["input_ids"], dtype=np.int64).copy()
        mask = np.asarray(encoded["attention_mask"], dtype=np.int64)
        placeholders = ids == token_id if token_id is not None else None
        if placeholders is not None:
            ids[placeholders] = self.processor.tokenizer.pad_token_id
        rows = self.run(f"tokens-{self.role}", {"input_ids": ids})[0]
        if features is not None:
            if int(placeholders.sum()) != len(features):
                raise ValueError("Media token count differs from Intel encoder output; input was truncated")
            rows[placeholders] = features  # copy encoder rows, no host embedding/projection/normalization
        return {"inputs_embeds": rows, "attention_mask": mask}

    def _vector(self, encoded, features=None, token_id=None):
        vector = self.run(f"text-{self.role}", self._text_inputs(encoded, features, token_id))[0]
        if vector.shape != (1, 768) or not np.isfinite(vector).all() or abs(np.linalg.norm(vector) - 1) >= 0.005:
            raise RuntimeError("Intel accelerator returned an invalid embedding")
        return vector[0]

    def texts(self, texts: list[str]) -> list[np.ndarray]:
        return [self._vector(self.processor.tokenizer(text, padding="max_length", truncation=True,
                    max_length=self.length, return_tensors="np")) for text in texts]

    def image(self, path: str, budget: int):
        if self.text_only:
            raise ValueError("Text-only worker cannot encode images")
        if budget not in (70, 140, 280, 560, 1120):
            raise ValueError("Unsupported image budget")
        from PIL import Image, ImageOps
        with Image.open(path) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
        encoded = self.processor(images=image, return_tensors="np",
            images_kwargs={"max_soft_tokens": budget},
            text_kwargs={"padding": "max_length", "max_length": self.length, "truncation": True})
        features, valid = self.run(f"vision-{budget}", {"pixel_values": np.asarray(encoded["pixel_values"], dtype=np.float32),
            "pixel_position_ids": np.asarray(encoded["image_position_ids"], dtype=np.int64)})
        token_id = self.processor.image_token_id
        return self._vector(encoded, features[valid.astype(bool)], token_id)

    def audio(self, path: str):
        if self.text_only:
            raise ValueError("Text-only worker cannot encode audio")
        import soundfile as sf
        audio, rate = sf.read(path, dtype="float32", always_2d=True, frames=480_000)
        if rate != 16_000 or audio.shape[1] != 1:
            raise ValueError("Expected the helper's mono 16 kHz WAV; resample before inference")
        if not len(audio):
            raise ValueError("Audio is empty")
        encoded = self.processor(audio=audio[:, 0], sampling_rate=rate, return_tensors="np",
            audio_kwargs={"padding": "max_length", "max_length": 480_000, "truncation": True},
            text_kwargs={"padding": "max_length", "max_length": self.length, "truncation": True})
        features, mask = self.run("audio", {
            "input_features": np.asarray(encoded["input_features"], dtype=np.float32),
            "input_features_mask": np.asarray(encoded["input_features_mask"], dtype=np.bool_)})
        return self._vector(encoded, features[mask.astype(bool)], self.processor.audio_token_id)
