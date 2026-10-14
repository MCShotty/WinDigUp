import Foundation

/// The same choice is passed to both the indexer and the query encoder.
public enum Acceleration: String, CaseIterable, Sendable {
    case auto, cpu, nvidia, amd
    case openvinoNPU = "openvino-npu"

    public static func selected(in environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let value = environment["DIGUP_BACKEND"] ?? "auto"
        guard let choice = Self(rawValue: value) else {
            throw WorkerError.failed("unknown DIGUP_BACKEND=\(value); choose auto, cpu, nvidia, amd or openvino-npu")
        }
        return choice
    }

    /// Device descriptions come from ggml, including the loaded backend's name.
    public struct Device: Sendable {
        public let backend: String
        public let name: String
        public let gpu: Bool

        public init(backend: String, name: String, gpu: Bool) {
            self.backend = backend
            self.name = name
            self.gpu = gpu
        }
    }

    /// nil means CPU. An explicit GPU choice must find that GPU, never silently fall back.
    public func deviceIndex(in devices: [Device]) throws -> Int? {
        switch self {
        case .cpu: return nil
        case .auto:
            return devices.firstIndex { $0.gpu && $0.backend.uppercased() == "CUDA" }
                ?? devices.firstIndex { $0.gpu }
        case .nvidia:
            if let index = devices.firstIndex(where: { $0.gpu && $0.backend.uppercased() == "CUDA" }) { return index }
        case .amd:
            if let index = devices.firstIndex(where: {
                let name = $0.name.lowercased()
                return $0.gpu && $0.backend.uppercased() == "VULKAN" && (name.contains("amd") || name.contains("radeon"))
            }) { return index }
        case .openvinoNPU:
            throw WorkerError.failed("OpenVINO NPU runs through the OpenVINO worker, not llama.cpp")
        }
        throw WorkerError.failed("\(rawValue) acceleration is unavailable; loaded devices: "
            + devices.map { "\($0.backend): \($0.name)" }.joined(separator: ", ")
            + ". Install the GPU driver and build/package the matching ggml backend.")
    }
}
