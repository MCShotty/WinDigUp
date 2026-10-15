#!/usr/bin/env python3
"""Installed setup -> model-ready -> folder scan -> vectors -> rendered search, with synthetic unit vectors.

This checks orchestration and real file I/O. It loads no neural model and does not validate GPU/NPU execution.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="digup-startup-") as folder:
        root = Path(folder)
        documents = root / "Documents العربية"
        documents.mkdir()
        (documents / "recipe.txt").write_text(
            "Lemon cake recipe. Cream butter and sugar, add three eggs, flour and the zest of two lemons. "
            "Bake the cake for forty minutes at 180 degrees, then pour warm lemon syrup over it.", encoding="utf-8")
        # Junctions need no developer-mode symlink privilege. A directory cycle must never be followed.
        subprocess.run(["cmd", "/c", "mklink", "/J", str(documents / "Loop"), str(documents)], check=True)
        bundle = root / "synthetic-bundle"
        bundle.mkdir()
        (bundle / "manifest.json").write_text("{}", encoding="utf-8")
        settings = root / "settings.json"
        settings.write_text(json.dumps({"setUp": False, "updateChecksOff": True,
            "applications": {"enabled": False}, "acceleration": {"backend": "openvino-npu",
                "python": sys.executable, "models": str(bundle)}}), encoding="utf-8")
        env = os.environ.copy()
        env.update(DIGUP_APP_TEST_LOG=str(root / "synthetic-requests.jsonl"),
            DIGUP_ACCELERATOR="openvino-npu", DIGUP_OPENVINO_PYTHON=sys.executable, DIGUP_OPENVINO_MODELS=str(bundle),
            DIGUP_OPENVINO_WORKER=str(Path(__file__).resolve().parents[1] / "tests/applications/synthetic-worker.py"))
        # Test the scanner independently of the desktop scheduler, then start setup with a separate fresh index.
        helper = args.app.resolve().parent / "helper" / "digup.exe"
        direct = subprocess.run([str(helper), "index", str(documents), "--index", str(root / "direct"), "--limit", "1"],
            env=env, text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=30)
        assert direct.returncode == 0, direct.stdout + direct.stderr
        with closing(sqlite3.connect(root / "direct" / "openvino-npu" / "index.sqlite")) as db:
            rows = db.execute("SELECT path, state FROM files").fetchall()
            assert len(rows) == 1 and rows[0][1] == "done", f"Direct scan followed a junction or failed: {rows}"
        command = [str(args.app.resolve()), "--index", str(root / "index"), "--settings", str(settings),
            "--offer", str(documents), "--hotkey", "Ctrl+Alt+Shift+D", "--debug-setup",
            "--debug-query", "lemon cake recipe", "--debug-quit"]
        try:
            result = subprocess.run(command, env=env, text=True, encoding="utf-8", errors="replace",
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
        except subprocess.TimeoutExpired as error:
            raise AssertionError(f"Installed indexing never reached its rendered search report. stdout={error.stdout!r} stderr={error.stderr!r}") from error
        print(result.stdout)
        print(result.stderr)
        reports = []
        for line in result.stdout.splitlines():
            try:
                reports.append(json.loads(line))
            except ValueError:
                pass
        assert result.returncode == 0, result.returncode
        assert any("recipe.txt" in json.dumps(report) for report in reports), "Indexed note was not rendered in search"
        effective = root / "index" / "openvino-npu"
        with closing(sqlite3.connect(effective / "index.sqlite")) as db:
            rows = db.execute("SELECT path, state FROM files").fetchall()
            assert any(path.endswith("recipe.txt") and state == "done" for path, state in rows), rows
            assert len(rows) == 1, f"Junction cycle was crawled: {rows}"
        saved = json.loads(settings.read_text(encoding="utf-8"))
        assert [Path(path) for path in saved["folders"]] == [documents] and saved["setUp"], saved
    print("PASS: installed setup, readiness handoff, Unicode folder scan, indexing and rendered file result (synthetic unit vectors; no inference)")


if __name__ == "__main__":
    main()
