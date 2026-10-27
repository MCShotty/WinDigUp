from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from devices import compile_gpu, device_inventory, kind_for, select_device, verify_selected


class Core:
    def __init__(self, devices=None):
        self.available_devices = list(devices or ["CPU", "GPU.0", "GPU.1", "NPU"])
    def get_property(self, device, key):
        values = {"FULL_DEVICE_NAME": "Intel Arc 140V" if device == "GPU.0" else "Intel device",
                  "DEVICE_TYPE": "INTEGRATED" if device == "GPU.0" else "DISCRETE",
                  "DEVICE_UUID": bytes([int(device[-1]) + 1]) if device.startswith("GPU.") else b"npu",
                  "DRIVER_VERSION": "fixture-driver"}
        return values.get(key)


@pytest.mark.parametrize("backend", ["CPU", "AUTO", "HETERO:NPU,CPU", "openvino-cpu", "GPU"])
def test_only_explicit_backends(backend):
    with pytest.raises(ValueError):
        kind_for(backend)


def test_integrated_intel_gpu_and_npu_are_independent():
    core = Core()
    gpu = device_inventory(core, "openvino-gpu")
    assert [d["id"] for d in gpu if d["available"]] == ["GPU.0"]
    assert select_device(core, "openvino-gpu")["id"] == "GPU.0"
    assert select_device(core, "openvino-npu")["id"] == "NPU"
    with pytest.raises(RuntimeError, match="unavailable"):
        select_device(core, "openvino-gpu", "GPU.1")
    with pytest.raises(RuntimeError, match="unavailable"):
        select_device(core, "openvino-gpu", "Vulkan0")


def test_missing_pin_never_selects_another_adapter():
    core = Core()
    identity = select_device(core, "openvino-gpu")["stableID"]
    assert select_device(core, "openvino-gpu", identity)["id"] == "GPU.0"
    core.available_devices = ["CPU", "GPU.1"]
    with pytest.raises(RuntimeError, match="unavailable"):
        select_device(core, "openvino-gpu", identity)


@pytest.mark.parametrize("execution", [["CPU"], ["GPU.0", "CPU"], ["AUTO:GPU"], ["GPU.1"], ["NPU"], []])
def test_gpu_execution_never_accepts_another_device(execution):
    class Compiled:
        def get_property(self, key):
            return execution
    selected = select_device(Core(), "openvino-gpu")
    with pytest.raises(RuntimeError, match="Exclusive"):
        verify_selected(Compiled(), selected)


def test_compile_retains_fp32_and_rejects_host_operations_before_submission():
    class Op:
        def get_type_name(self): return "MatMul"
        def get_friendly_name(self): return "projection"
    class Model:
        def get_ops(self): return [Op()]
    class Compiled:
        def get_property(self, key):
            return ["GPU.0"] if key == "EXECUTION_DEVICES" else "f32"
    class Compiler(Core):
        mapped = "CPU"
        compiled = False
        def query_model(self, model, device):
            assert device == "GPU.0"
            return {"projection": self.mapped}
        def compile_model(self, model, device, config):
            assert config["INFERENCE_PRECISION_HINT"] == "f32"
            assert config["ENABLE_PROFILING"] is True
            assert device == "GPU.0"
            self.compiled = True
            return Compiled()
    core = Compiler()
    selected = select_device(core, "openvino-gpu")
    with pytest.raises(RuntimeError, match="CPU fallback disabled"):
        compile_gpu(core, Model(), "text", selected)
    assert not core.compiled
    core.mapped = "GPU.1"
    with pytest.raises(RuntimeError, match="CPU fallback disabled"):
        compile_gpu(core, Model(), "text", selected)
    assert not core.compiled
    core.mapped = "GPU.0"
    compile_gpu(core, Model(), "text", selected)
    assert core.compiled


def test_stable_identity_follows_a_device_when_ordinal_changes():
    class Reordered(Core):
        def get_property(self, device, key):
            if key == "DEVICE_UUID": return b"fixed"
            if key == "DEVICE_TYPE": return "INTEGRATED"
            return super().get_property("GPU.0", key)
    first = Reordered(["GPU.0"])
    identity = select_device(first, "openvino-gpu")["stableID"]
    assert select_device(Reordered(["GPU.2"]), "openvino-gpu", identity)["id"] == "GPU.2"


@pytest.mark.parametrize("kind", ["GPU", "NPU"])
@pytest.mark.parametrize("selected,reported", [("", ".0"), (".0", ""), (".0", ".0"), ("", "")])
def test_primary_device_aliases_do_not_reject_valid_openvino_receipts(kind, selected, reported):
    class Compiled:
        def get_property(self, key): return [kind + reported]
    verify_selected(Compiled(), {"id":kind+selected, "backend":"openvino-gpu" if kind=="GPU" else "openvino-npu"})


def test_primary_alias_never_identifies_a_secondary_device():
    class Compiled:
        def get_property(self, key): return ["GPU"]
    with pytest.raises(RuntimeError, match="Exclusive"):
        verify_selected(Compiled(), {"id":"GPU.1", "backend":"openvino-gpu"})


def test_raw_primary_alias_does_not_bypass_multi_adapter_reselection():
    class Integrated(Core):
        def get_property(self, device, key):
            if key == "DEVICE_TYPE": return "INTEGRATED"
            return super().get_property(device, key)
    core = Integrated(["GPU.0", "GPU.1"])
    with pytest.raises(RuntimeError, match="stable OpenVINO identity"):
        select_device(core, "openvino-gpu", "GPU")
    identity = device_inventory(core, "openvino-gpu")[1]["stableID"]
    assert select_device(core, "openvino-gpu", identity)["id"] == "GPU.1"
