"""OpenVINO device identity and exclusive hardware execution policy."""
import hashlib
import re


def kind_for(backend):
    if backend == "openvino-npu":
        return "NPU"
    if backend == "openvino-gpu":
        return "GPU"
    raise ValueError("Choose openvino-npu or openvino-gpu; CPU/AUTO/HETERO are unavailable")


def property_value(core, device, key):
    try:
        return core.get_property(device, key)
    except Exception:
        return None


def device_inventory(core, backend):
    kind = kind_for(backend)
    devices = []
    for device in core.available_devices:
        if not re.fullmatch(kind + r"(?:\.\d+)?", device):
            continue
        name = str(property_value(core, device, "FULL_DEVICE_NAME") or device)
        device_type = str(property_value(core, device, "DEVICE_TYPE") or "").upper().split(".")[-1]
        eligible = kind == "NPU" or ("INTEL" in name.upper() and device_type == "INTEGRATED")
        uuid = property_value(core, device, "DEVICE_UUID")
        try:
            uuid = bytes(uuid).hex() if uuid is not None else ""
        except (TypeError, ValueError):
            text = str(uuid or "").replace("-", "")
            uuid = text.lower() if re.fullmatch(r"[0-9a-fA-F]{32}", text) else ""
        if uuid and not uuid.strip("0"):
            uuid = ""
        hardware = "|".join(str(property_value(core, device, key) or "") for key in
                            ("FULL_DEVICE_NAME", "DEVICE_ARCHITECTURE", "GPU_DEVICE_ID"))
        stable = "OV-" + kind + "-" + (uuid or hashlib.sha256(hardware.encode()).hexdigest())
        devices.append({"id": device, "stableID": stable, "name": name, "backend": backend,
                        "vendorID": 0x8086, "hardware": True, "available": eligible,
                        "deviceType": device_type, "driverDescription": str(
                            property_value(core, device, "DRIVER_VERSION") or ""),
                        "message": "" if eligible else "This path requires an Intel integrated GPU reported by OpenVINO."})
    for device in devices:
        if sum(d["stableID"] == device["stableID"] for d in devices) > 1:
            device["available"] = False
            device["message"] = "The driver does not expose unique identities for these devices; update the Intel driver."
    return devices


def select_device(core, backend, requested=""):
    devices = device_inventory(core, backend)
    eligible = [d for d in devices if d["available"]]
    if requested:
        matches = [d for d in eligible if requested == d["stableID"] or requested in device_aliases(d["id"], kind_for(backend))]
        if len(matches) != 1:
            raise RuntimeError("The selected OpenVINO device is unavailable. Refresh devices and re-select it; no fallback was attempted.")
        selected = matches[0]
        if requested == selected["id"] and len(eligible) > 1:
            raise RuntimeError("Select a stable OpenVINO identity when several devices are available.")
        return selected
    if len(eligible) != 1:
        target = "Intel NPU" if backend == "openvino-npu" else "Intel integrated GPU"
        if not eligible:
            raise RuntimeError(target + " not available to OpenVINO. Check the Intel driver and device status; CPU fallback is disabled.")
        raise RuntimeError("Several OpenVINO devices are available. Select one explicitly.")
    return eligible[0]


def device_aliases(device, kind):
    return {kind, kind + ".0"} if device in (kind, kind + ".0") else {device}


def verify_selected(compiled, selected):
    devices = list(compiled.get_property("EXECUTION_DEVICES"))
    expected = selected["id"]
    kind = kind_for(selected["backend"])
    # OpenVINO uses both spellings for the same primary device.
    allowed = device_aliases(expected, kind)
    if not devices or any(str(device) not in allowed for device in devices):
        raise RuntimeError("Exclusive " + expected + " execution required, got " + repr(devices) + "; CPU fallback disabled")


def compile_gpu(core, model, name, selected):
    device = selected["id"]
    supported = core.query_model(model, device)
    allowed_ops = device_aliases(device, "GPU") | {"GPU"}
    unsupported = {op.get_type_name() for op in model.get_ops()
                   if op.get_type_name() not in ("Parameter", "Result", "Constant")
                   and str(supported.get(op.get_friendly_name(), "")) not in allowed_ops}
    if unsupported:
        raise RuntimeError("Intel GPU does not support " + name + ": " + ", ".join(sorted(unsupported)) + "; CPU fallback disabled")
    compiled = core.compile_model(model, device, {
        "PERFORMANCE_HINT": "LATENCY", "ENABLE_PROFILING": True, "INFERENCE_PRECISION_HINT": "f32"})
    verify_selected(compiled, selected)
    precision = str(compiled.get_property("INFERENCE_PRECISION_HINT")).lower()
    if "f32" not in precision and "float32" not in precision:
        raise RuntimeError("Intel GPU did not retain the required FP32 precision profile")
    return compiled
