from pathlib import Path
from types import SimpleNamespace
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_model import MODEL, prepare


def test_download_pins_the_resolved_revision_and_never_uses_cached_credentials(tmp_path, monkeypatch):
    monkeypatch.delenv("DIGUP_HF_DOWNLOAD_TOKEN", raising=False)
    calls = []
    source = tmp_path / "snapshot"
    source.mkdir()
    revision = "a" * 40
    class API:
        def __init__(self, **kwargs):
            assert kwargs == {"endpoint": "https://huggingface.co", "token": False}
        def model_info(self, model):
            assert model == MODEL
            return SimpleNamespace(sha=revision)
    def download(model, **kwargs):
        calls.append(kwargs)
        assert model == MODEL and kwargs["revision"] == revision and kwargs["token"] is False
        assert "*.safetensors" in kwargs["allow_patterns"] and "*.py" not in kwargs["allow_patterns"]
        return str(source)
    exported = []
    monkeypatch.setitem(sys.modules, "huggingface_hub", SimpleNamespace(HfApi=API, snapshot_download=download))
    monkeypatch.setitem(sys.modules, "export_model", SimpleNamespace(export_bundle=lambda *args: exported.append(args)))
    args = SimpleNamespace(source=None, revision=None, download=True, cache_root=tmp_path / "cache", output=tmp_path / "bundle")
    prepare(args)
    assert len(calls) == 1 and exported[0][:3] == (source, args.output, revision)


def test_local_preparation_never_contacts_a_model_host(tmp_path, monkeypatch):
    exported = []
    class API:
        def __init__(self, **kwargs):
            raise AssertionError("Local preparation attempted network work")
    monkeypatch.setitem(sys.modules, "huggingface_hub", SimpleNamespace(HfApi=API))
    monkeypatch.setitem(sys.modules, "export_model", SimpleNamespace(export_bundle=lambda *args: exported.append(args)))
    args = SimpleNamespace(source=tmp_path, revision="b"*40, download=False, output=tmp_path / "bundle")
    prepare(args)
    assert exported[0][:3] == (tmp_path, args.output, "b"*40)


def test_gated_download_has_a_readable_local_checkpoint_recovery(tmp_path, monkeypatch):
    class API:
        def __init__(self, **kwargs): pass
        def model_info(self, model):
            raise RuntimeError("401: access requires license acceptance")
    monkeypatch.setitem(sys.modules, "huggingface_hub", SimpleNamespace(HfApi=API))
    args = SimpleNamespace(source=None, revision=None, download=True, cache_root=tmp_path, output=tmp_path / "bundle")
    with pytest.raises(RuntimeError, match="local snapshot folder"):
        prepare(args)

def test_explicit_token_is_scoped_to_download_and_redacted_on_failure(tmp_path, monkeypatch, capsys):
    token = "hf_fixture_secret"
    monkeypatch.setenv("DIGUP_HF_DOWNLOAD_TOKEN", token)
    class API:
        def __init__(self, **kwargs):
            assert kwargs == {"endpoint": "https://huggingface.co", "token": token}
        def model_info(self, model):
            raise RuntimeError("401: token " + token)
    monkeypatch.setitem(sys.modules, "huggingface_hub", SimpleNamespace(HfApi=API))
    args = SimpleNamespace(source=None, revision=None, download=True, cache_root=tmp_path, output=tmp_path / "bundle")
    with pytest.raises(RuntimeError) as result:
        prepare(args)
    assert token not in str(result.value)
    assert "[redacted]" in str(result.value)
    import os
    assert "DIGUP_HF_DOWNLOAD_TOKEN" not in os.environ
