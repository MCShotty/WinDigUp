import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from npu_runtime import NPURuntime, bundle_id, check_parity, compile_npu, only_npu, validate_bundle, verify_execution


@pytest.mark.parametrize("devices", [[], ["CPU"], ["NPU", "CPU"], ["AUTO:NPU"], ["HETERO:NPU,CPU"], ["GPU"], ["NPU.fake"]])
def test_reject_other_execution_devices(devices):
    class Compiled:
        def get_property(self, key):
            assert key == "EXECUTION_DEVICES"
            return devices
    assert not only_npu(devices)
    with pytest.raises(RuntimeError, match="CPU fallback disabled"):
        verify_execution(Compiled())


@pytest.mark.parametrize("devices", [["NPU"], ["NPU.0"], ["NPU.0", "NPU.1"]])
def test_explicit_npu(devices):
    assert only_npu(devices)


def test_no_npu_does_not_read_or_compile_model(tmp_path):
    class Core:
        available_devices = ["CPU", "GPU.0"]
        def read_model(self, *_):
            raise AssertionError("A CPU/GPU model must never load as fallback")
        def compile_model(self, *_):
            raise AssertionError("A CPU/GPU model must never compile as fallback")
    with pytest.raises(RuntimeError, match="Intel NPU not found"):
        NPURuntime(tmp_path / "missing", core=Core())


def test_bad_precision_and_masks_rejected():
    check_parity(np.array([1., 2.]), np.array([1., 2.]), "same")
    for values in ([np.inf, 1], [np.nan, 2], [-1, -2], [10, 20], [0, 0]):
        with pytest.raises(RuntimeError, match="parity failed"):
            check_parity(values, np.array([1., 2.]), "bad")
    with pytest.raises(RuntimeError, match="different mask"):
        check_parity(np.array([True, False]), np.array([True, True]), "mask")


@pytest.mark.parametrize("mapped_device", ["CPU", "", "NPU"])
def test_compile_disables_wrapper_and_rejects_partial_device_support(mapped_device):
    class Op:
        def get_type_name(self): return "MatMul"
        def get_friendly_name(self): return "projection"
    class Model:
        def get_ops(self): return [Op()]
    class Compiled:
        def get_property(self, key): return ["NPU"]
    class Core:
        compiled = False
        def query_model(self, model, device, config):
            assert device == "NPU" and config["NPU_USE_NPUW"] is False
            return {"projection": mapped_device}
        def compile_model(self, model, device, config):
            assert mapped_device == "NPU", "unsupported operations must fail before compilation"
            assert device == "NPU" and config["NPU_USE_NPUW"] is False
            assert config["ENABLE_PROFILING"] is True
            self.compiled = True
            return Compiled()
    core = Core()
    if mapped_device == "NPU":
        compile_npu(core, Model(), "text")
        assert core.compiled
    else:
        with pytest.raises(RuntimeError, match="does not support"):
            compile_npu(core, Model(), "text")
        assert not core.compiled


def test_bundle_integrity_and_required_media(tmp_path):
    manifest = {"format": 1, "model": "google/embeddinggemma-2", "dim": 768, "graphs": {}, "files": {}}
    manifest["bundle_id"] = bundle_id(manifest)
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="all image budgets"):
        validate_bundle(tmp_path)
    manifest["dim"] = 512
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match="fingerprint"):
        validate_bundle(tmp_path)
