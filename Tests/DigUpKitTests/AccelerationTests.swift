import DigUpKit
import Testing

@Suite struct AccelerationTests {
    let devices: [Acceleration.Device] = [
        .init(backend: "CPU", name: "Intel CPU", gpu: false),
        .init(backend: "Vulkan", name: "Intel integrated graphics", gpu: true),
        .init(backend: "Vulkan", name: "AMD Radeon RX 7900", gpu: true),
        .init(backend: "CUDA", name: "NVIDIA RTX 4070", gpu: true),
    ]

    @Test func explicitDevices() throws {
        #expect(try Acceleration.cpu.deviceIndex(in: devices) == nil)
        #expect(try Acceleration.amd.deviceIndex(in: devices) == 2)
        #expect(try Acceleration.nvidia.deviceIndex(in: devices) == 3)
        #expect(try Acceleration.auto.deviceIndex(in: devices) == 3)
        #expect(try Acceleration.auto.deviceIndex(in: []) == nil)
    }

    @Test func unavailableNeverFallsBack() {
        #expect(throws: WorkerError.self) { try Acceleration.amd.deviceIndex(in: Array(devices.prefix(2))) }
        #expect(throws: WorkerError.self) { try Acceleration.nvidia.deviceIndex(in: Array(devices.prefix(3))) }
        #expect(throws: WorkerError.self) { try Acceleration.openvinoNPU.deviceIndex(in: devices) }
    }

    @Test func environmentIsValidated() throws {
        #expect(try Acceleration.selected(in: [:]) == .auto)
        #expect(try Acceleration.selected(in: ["DIGUP_BACKEND": "openvino-npu"]) == .openvinoNPU)
        #expect(throws: WorkerError.self) { try Acceleration.selected(in: ["DIGUP_BACKEND": "typo"]) }
    }
}
