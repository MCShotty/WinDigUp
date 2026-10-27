import Foundation

/// Inference is always on a hardware accelerator. Host preprocessing and I/O are separate from model execution.
public enum Acceleration: String, Sendable, CaseIterable {
    case vulkan, amdVulkan = "amd-vulkan", nvidiaCUDA = "nvidia-cuda", openvinoNPU = "openvino-npu", openvinoGPU = "openvino-gpu", metal

    public var isOpenVINO: Bool { self == .openvinoNPU || self == .openvinoGPU }
    public var openVINODeviceKind: String { self == .openvinoGPU ? "GPU" : "NPU" }

    public func acceptsOpenVINOReceipt(_ info: WorkerInfo) -> Bool {
        guard isOpenVINO, info.executionPolicy == "accelerator-only", info.dim == 768,
              let device = info.device else { return false }
        let prefix = openVINODeviceKind + "."
        let suffix = device.hasPrefix(prefix) ? String(device.dropFirst(prefix.count)) : ""
        guard device == openVINODeviceKind || (!suffix.isEmpty && suffix.utf8.allSatisfy({ (48...57).contains($0) })) else { return false }
        return info.backend == rawValue || (self == .openvinoNPU && info.backend == nil)
    }

    public static let cudaPrecision = "cuda-fp32-v1"
    /// Matches the shipped real-code targets; unknown future SMs require a new validated build.
    public static let cudaComputeCapabilities: Set<Int> = [75, 86, 89, 120]

    /// Classify a failed CUDA operation from bounded native diagnostics; never retry another execution path.
    public static func cudaFailure(diagnostic: String, fallback: String) -> String {
        let text = diagnostic.lowercased()
        if ["out of memory", "cudaerrormemoryallocation", "cublas_status_alloc_failed"].contains(where: text.contains) {
            return "insufficient_vram: Not enough GPU memory for the CUDA model. Free GPU memory and retry. CPU fallback is disabled."
        }
        if ["unsupported op", "operation not supported", "no kernel image", "accelerator-only: refusing"].contains(where: text.contains) {
            return "unsupported_operation: A required operation could not run on the selected CUDA GPU. Check the driver and Activity details. CPU fallback is disabled."
        }
        return fallback
    }

    public var registry: String {
        switch self {
        case .nvidiaCUDA: "cuda"
        case .metal: "metal"
        case .openvinoNPU, .openvinoGPU: "openvino"
        default: "vulkan"
        }
    }

    /// --index is always the base directory, including when its last component resembles a backend name.
    public func indexDirectory(base: URL) -> URL {
        switch self {
        case .nvidiaCUDA, .openvinoNPU, .openvinoGPU: base.appendingPathComponent(rawValue).standardizedFileURL
        default: base.standardizedFileURL
        }
    }

    public func accepts(_ device: AcceleratorDevice) -> Bool {
        guard device.hardware, device.backend.lowercased() == registry else { return false }
        switch self {
        case .nvidiaCUDA: return device.vendorID == 0x10de && Self.cudaComputeCapabilities.contains(device.computeCapability ?? 0) && (device.driverVersion ?? 0) >= 12090
        case .amdVulkan: return device.vendorID == 0x1002
        case .vulkan: return device.vendorID != 0x10de && device.vendorID != 0
        case .metal: return true
        case .openvinoNPU, .openvinoGPU: return false
        }
    }

    public static func requireInferenceReady(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let value = environment["DIGUP_RESOURCE_PROFILE"], !["quiet", "balanced", "faster"].contains(value) {
            throw WorkerError.failed("DIGUP_RESOURCE_PROFILE must be quiet, balanced, or faster.")
        }
        if let value=environment["DIGUP_GPU_JOBS"],Int(value).map({(0...3).contains($0)}) != true {
            throw WorkerError.failed("DIGUP_GPU_JOBS must be 0 (automatic), 1, 2, or 3.")
        }
        if let error = environment["DIGUP_ACCELERATOR_ERROR"], !error.isEmpty { throw WorkerError.failed(error) }
        if environment["DIGUP_ACCELERATOR"] == "nvidia-cuda" {
            if environment["GGML_CUDA_ENABLE_UNIFIED_MEMORY"] != nil {
                throw WorkerError.failed("CUDA managed-memory spill is disabled by the accelerator-only policy.")
            }
            if let precision = environment["GGML_CUDA_CUBLAS_COMPUTE_TYPE"], !["f32", "fp32", "auto"].contains(precision.lowercased()) {
                throw WorkerError.failed("The CUDA precision profile requires FP32 activations. Remove GGML_CUDA_CUBLAS_COMPUTE_TYPE.")
            }
        }
        if environment["DIGUP_GPU_SELECTION_REQUIRED"] == "1" {
            throw WorkerError.failed("Re-select your GPU in Settings. A legacy Vulkan device number cannot safely identify the same adapter after this upgrade.")
        }
        if environment["DIGUP_ACCELERATOR_DISCOVERY_PENDING"] == "1" {
            throw WorkerError.failed("Hardware discovery is preparing the initial accelerator selection. App name search and launching remain available.")
        }
    }

    public static func selected(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        if environment["DIGUP_DEVICE"]?.lowercased() == "cpu" {
            throw WorkerError.failed("CPU inference is disabled. Choose NVIDIA CUDA, AMD Vulkan or Intel OpenVINO GPU/NPU.")
        }
        if environment["DIGUP_WORKER_DIR"] != nil {
            throw WorkerError.failed("Unverified worker overrides are disabled by the accelerator-only policy.")
        }
        #if os(macOS)
        let fallback = Self.metal
        #else
        let fallback = Self.vulkan
        #endif
        guard let chosen = environment["DIGUP_ACCELERATOR"], !chosen.isEmpty else { return fallback }
        if chosen == "nvidia-vulkan" {
            throw WorkerError.failed("NVIDIA Vulkan has been removed. Use DIGUP_ACCELERATOR=nvidia-cuda with an RTX 20-series or newer GPU.")
        }
        guard let result = Self(rawValue: chosen) else {
            throw WorkerError.failed("Unknown accelerator '\(chosen)'. CPU fallback is disabled.")
        }
        return result
    }

    /// The speed cache may describe a different accelerator, or an upstream CPU preference.
    public static var cacheKey: String {
        [(try? selected())?.rawValue ?? "invalid",
         ProcessInfo.processInfo.environment["DIGUP_GPU"] ?? "",
         ProcessInfo.processInfo.environment["DIGUP_OPENVINO_MODELS"] ?? ""].joined(separator: ":")
    }
}

/// Driver discovery is separate from a successful inference receipt. Device IDs are never cross-backend aliases.
public struct AcceleratorDevice: Codable, Sendable, Equatable {
    public var id: String
    public var backend: String
    public var name: String
    public var vendorID: UInt32
    public var stableID: String
    public var hardware: Bool
    public var computeCapability: Int?
    public var driverVersion: Int?
    public var runtimeVersion: Int?

    public init(id: String, backend: String, name: String, vendorID: UInt32, stableID: String = "", hardware: Bool = true,
                computeCapability: Int? = nil, driverVersion: Int? = nil, runtimeVersion: Int? = nil) {
        self.id = id; self.backend = backend; self.name = name; self.vendorID = vendorID; self.stableID = stableID
        self.hardware = hardware; self.computeCapability = computeCapability; self.driverVersion = driverVersion
        self.runtimeVersion = runtimeVersion
    }

    public func matches(_ requested: String?) -> Bool {
        guard let requested, !requested.isEmpty else { return true }
        return requested == id || (!stableID.isEmpty && requested == stableID)
    }

    public var cacheIdentity: String {
        [backend, stableID.isEmpty ? id : stableID, String(driverVersion ?? 0), String(runtimeVersion ?? 0)]
            .joined(separator: ":")
    }
}
