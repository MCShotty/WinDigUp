#!/usr/bin/env python3
"""User-requested download and offline preparation of the fixed EmbeddingGemma checkpoint."""
import argparse
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
MODEL = "google/embeddinggemma-2"


def report(phase, message):
    print(json.dumps({"event": "preparation", "phase": phase, "message": message}, ensure_ascii=True), flush=True)


def prepare(args):
    source, revision = args.source, args.revision
    access_token = os.environ.pop("DIGUP_HF_DOWNLOAD_TOKEN", "")
    authorization = access_token or False
    if args.download:
        os.environ["HF_ENDPOINT"] = "https://huggingface.co"
        from huggingface_hub import HfApi, snapshot_download
        report("downloading", "Resolving the model checkpoint revision. No search queries or private files are sent.")
        try:
            revision = HfApi(endpoint="https://huggingface.co", token=authorization).model_info(MODEL).sha
            if not re.fullmatch(r"[0-9a-f]{40}", revision):
                raise ValueError("The model host did not return a pinned checkpoint revision.")
            report("downloading", "Downloading the full checkpoint. Partial downloads can be resumed on another attempt.")
            source = Path(snapshot_download(MODEL, revision=revision, cache_dir=args.cache_root, token=authorization,
                allow_patterns=["*.json", "*.safetensors", "*.model", "*.txt", "*.jinja", "*.tiktoken", "LICENSE", "LICENSE.*"]))
        except Exception as error:
            detail = str(error).replace(access_token, "[redacted]") if access_token else str(error)
            raise RuntimeError("Model download failed. If access requires an account, accept the model license and provide a read-only token under Download access, or choose a local snapshot folder. " + detail[:700]) from None
    if source is None or not source.is_dir() or not re.fullmatch(r"[0-9a-f]{40}", revision or ""):
        raise ValueError("Choose a complete local checkpoint and its full 40-character revision.")
    from export_model import export_bundle
    export_bundle(source, args.output, revision, report)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--cache-root", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        prepare(args)
    except Exception as error:
        report("failed", str(error)[:1500])
        raise SystemExit(1)
