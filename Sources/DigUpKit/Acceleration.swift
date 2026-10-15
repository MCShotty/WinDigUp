import Foundation

/// Inference is always on a hardware accelerator. Host preprocessing and I/O are separate from model execution.
public enum Acceleration: String, Sendable, CaseIterable {
    case vulkan, amdVulkan = "amd-vulkan", nvidiaVulkan = "nvidia-vulkan", openvinoNPU = "openvino-npu", metal

    public static func selected(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        if environment["DIGUP_DEVICE"]?.lowercased() == "cpu" {
            throw WorkerError.failed("CPU inference is disabled. Choose Vulkan GPU or OpenVINO NPU.")
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
        guard let result = Self(rawValue: chosen) else {
            throw WorkerError.failed("Unknown accelerator '\(chosen)'. CPU fallback is disabled.")
        }
        return result
    }

    /// The speed cache may describe a different accelerator, or an upstream CPU preference.
    public static var cacheKey: String {
        [ProcessInfo.processInfo.environment["DIGUP_ACCELERATOR"] ?? "vulkan",
         ProcessInfo.processInfo.environment["DIGUP_GPU"] ?? "",
         ProcessInfo.processInfo.environment["DIGUP_OPENVINO_MODELS"] ?? ""].joined(separator: ":")
    }
}
