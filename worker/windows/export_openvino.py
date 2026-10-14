"""Export a LOCAL EmbeddingGemma 2 snapshot for WinDigUp's Intel NPU backend.

Uses fixed 512/2048-token shapes, FP32 weights, masked mean pooling and L2 normalization.
Checks OpenVINO CPU outputs against independent Transformers outputs before publishing a bundle.
Use --verify-device NPU on the Windows machine to also gate export on that device's parity.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile

import numpy as np

from openvino_worker import DIM, check_reference, sha256

PROBES = [
    "task: search result | query: a dog on the beach",
    "task: search result | query: ملفات وصور من العطلة",
    "title: notes | text: বাংলায় লেখা একটি নোট",
    "title: long document | text: " + "An archive of scientific documents and family photographs. " * 200,
]


def export(source, output, revision, text_only=False, verify_device="CPU"):
    import openvino as ov
    import torch
    import torch.nn.functional as functional
    from safetensors.torch import save_file
    from transformers import AutoConfig, AutoModel, AutoProcessor, AutoTokenizer

    if not source.is_dir():
        raise ValueError("--source must be a local Hugging Face snapshot, downloaded before export")
    if output.exists():
        raise ValueError("--output already exists; choose a new folder so an installed bundle cannot be half overwritten")
    config = AutoConfig.from_pretrained(source, local_files_only=True, trust_remote_code=False)
    if config.model_type != "embedding_gemma2" or config.text_config.embedding_dim != DIM:
        raise ValueError("the source must be google/embeddinggemma-2 (768 dimensions)")
    revision = revision or getattr(config, "_commit_hash", None)
    if not revision or len(revision) < 7:
        raise ValueError("provide --revision with the source snapshot's immutable commit")
    model = AutoModel.from_pretrained(source, local_files_only=True, trust_remote_code=False,
                                     dtype=torch.float32, attn_implementation="eager").eval()
    tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True, trust_remote_code=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=output.name + ".export-", dir=output.parent))
    try:
        processor_folder = temporary / "processor"
        tokenizer.save_pretrained(processor_folder)
        config.save_pretrained(processor_folder)
        if not text_only:
            AutoProcessor.from_pretrained(source, local_files_only=True, trust_remote_code=False).save_pretrained(processor_folder)
            prefixes = ("vision_tower.", "audio_tower.", "embed_vision.", "embed_audio.")
            media_state = {key: tensor.contiguous() for key, tensor in model.state_dict().items() if key.startswith(prefixes)}
            save_file(media_state, str(temporary / "media.safetensors"))
            del media_state
        table = model.language_model.embed_tokens.weight.detach().float().numpy()
        scale = float(model.language_model.embed_tokens.embed_scale.item())
        np.save(temporary / "token_embeddings.npy", table, allow_pickle=False)
        manifest = {
            "schema": 1, "model": "google/embeddinggemma-2", "revision": revision,
            "dimension": DIM, "pipeline": 1, "precision": "f32", "embedding_scale": scale,
            "graphs": {}, "files": {}, "probes": [{"text": text, "vectors": {}} for text in PROBES],
        }

        class TextGraph(torch.nn.Module):
            def __init__(self, length):
                super().__init__()
                self.language_model = model.language_model
                positions = torch.arange(length, dtype=torch.int64)
                self.register_buffer("positions", positions.unsqueeze(0), persistent=False)
                self.register_buffer("sliding", (positions[:, None] - positions[None, :]).abs()
                                     <= config.text_config.sliding_window, persistent=False)

            def forward(self, inputs_embeds, attention_mask):
                # Explicit masks avoid tracing Transformers' generic mask factory as Python control flow.
                valid = attention_mask[:, None, None, :].bool()
                zero = torch.zeros((), dtype=torch.float32, device=inputs_embeds.device)
                negative = torch.full((), torch.finfo(torch.float32).min, device=inputs_embeds.device)
                masks = {"full_attention": torch.where(valid, zero, negative),
                         "sliding_attention": torch.where(valid & self.sliding[None, None], zero, negative)}
                hidden = self.language_model(inputs_embeds=inputs_embeds, attention_mask=masks,
                                             position_ids=self.positions, return_dict=True).last_hidden_state.float()
                weights = attention_mask.unsqueeze(-1).float()
                pooled = (hidden * weights).sum(1) / weights.sum(1).clamp(min=1e-9)
                return functional.normalize(pooled, p=2, dim=-1)

        def inputs(text, length):
            tokens = tokenizer([text], truncation=True, max_length=length, return_tensors="pt")
            ids = tokens["input_ids"].numpy()
            count = ids.shape[1]
            embeddings = np.zeros((1, length, table.shape[1]), np.float32)
            mask = np.zeros((1, length), np.int64)
            embeddings[:, :count] = table[ids] * scale
            mask[:, :count] = tokens["attention_mask"].numpy()
            with torch.inference_mode():
                hidden = model(**tokens).last_hidden_state.float()
                weights = tokens["attention_mask"].unsqueeze(-1).float()
                reference = functional.normalize((hidden * weights).sum(1) / weights.sum(1).clamp(min=1e-9), p=2, dim=-1)
            return embeddings, mask, reference.numpy()

        core = ov.Core()
        if verify_device not in core.available_devices:
            raise RuntimeError(f"device {verify_device} is not available: {core.available_devices}")
        for name, length in (("query", 512), ("index", 2048)):
            print(f"Exporting {name} backbone ({length} tokens, FP32)", file=sys.stderr, flush=True)
            wrapper = TextGraph(length).eval()
            embeddings, mask, _ = inputs(PROBES[0], length)
            converted = ov.convert_model(wrapper, example_input=(torch.from_numpy(embeddings), torch.from_numpy(mask)))
            converted.inputs[0].get_tensor().set_names({"inputs_embeds"})
            converted.inputs[1].get_tensor().set_names({"attention_mask"})
            converted.outputs[0].get_tensor().set_names({"sentence_embedding"})
            converted.reshape({"inputs_embeds": [1, length, table.shape[1]], "attention_mask": [1, length]})
            graph_path = temporary / f"text-{length}.xml"
            ov.save_model(converted, str(graph_path), compress_to_fp16=False)
            compiled = core.compile_model(str(graph_path), verify_device, {"PERFORMANCE_HINT": "LATENCY"})
            execution = [str(item) for item in compiled.get_property("EXECUTION_DEVICES")]
            if not execution or any(item.split(".")[0] != verify_device for item in execution):
                raise RuntimeError(f"OpenVINO used {execution}, expected {verify_device}")
            for probe in manifest["probes"]:
                embeddings, mask, reference = inputs(probe["text"], length)
                actual = compiled({"inputs_embeds": embeddings, "attention_mask": mask})[compiled.output("sentence_embedding")]
                cosine = check_reference(actual, reference)
                print(f"  {name} parity: {cosine:.6f}", file=sys.stderr)
                probe["vectors"][name] = reference[0].tolist()
            manifest["graphs"][name] = {"path": graph_path.name, "tokens": length}
            del compiled, converted, wrapper
        for path in sorted(temporary.rglob("*")):
            if path.is_file():
                manifest["files"][path.relative_to(temporary).as_posix()] = sha256(path)
        (temporary / "digup-openvino.json").write_text(json.dumps(manifest, indent=2, allow_nan=False), encoding="utf-8")
        temporary.rename(output)
        print(f"Exported verified bundle to {output}", file=sys.stderr)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--revision", help="source model commit, not the GGUF conversion commit")
    parser.add_argument("--text-only", action="store_true", help="exclude vision/audio; unsuitable for the app's full index")
    parser.add_argument("--verify-device", choices=("CPU", "NPU"), default="CPU")
    args = parser.parse_args()
    export(args.source.resolve(), args.output.resolve(), args.revision, args.text_only, args.verify_device)


if __name__ == "__main__":
    main()
