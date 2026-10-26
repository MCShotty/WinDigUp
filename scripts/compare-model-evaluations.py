#!/usr/bin/env python3
"""Compare model-only evidence without changing a model, index, threshold or fingerprint."""
import argparse
import json
from pathlib import Path

import model_evaluation as contract


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = contract.compare(contract.load_json(args.baseline), contract.load_json(args.candidate))
    value = json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    if args.output:
        if args.output.exists():
            parser.error("Use a new output file so earlier evidence is retained")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(value, encoding="utf-8")
    print(value, end="")
    return 1 if report["status"] == "rejected" else 2


if __name__ == "__main__":
    raise SystemExit(main())
