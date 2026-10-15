import Foundation
import Testing
@testable import DigUpKit

struct AccelerationTests {
    @Test func rejectsCPUAndUnverifiedWorkers() throws {
        #expect(throws: WorkerError.self) { try Acceleration.selected(environment: ["DIGUP_DEVICE": "cpu"]) }
        #expect(throws: WorkerError.self) { try Acceleration.selected(environment: ["DIGUP_DEVICE": "CPU"]) }
        #expect(throws: WorkerError.self) { try Acceleration.selected(environment: ["DIGUP_WORKER_DIR": "worker"]) }
        #expect(throws: WorkerError.self) { try Acceleration.selected(environment: ["DIGUP_ACCELERATOR": "AUTO:NPU,CPU"]) }
        #expect(throws: WorkerError.self) { try Acceleration.selected(environment: ["DIGUP_ACCELERATOR": "cpu"]) }
    }

    @Test func selectsOnlyNamedAccelerators() throws {
        for device in Acceleration.allCases {
            #expect(try Acceleration.selected(environment: ["DIGUP_ACCELERATOR": device.rawValue]) == device)
        }
        #if os(macOS)
        #expect(try Acceleration.selected(environment: [:]) == .metal)
        #else
        #expect(try Acceleration.selected(environment: [:]) == .vulkan)
        #endif
    }

    @Test func fingerprintsDoNotMixRuntimesAndDecodeDeviceProof() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = #"{"model":"google/embeddinggemma-2","revision":"abc1234","runtime":"openvino-npu-v1-example","dtype":"fp32","dim":768,"text_only":true,"device":"NPU","execution_policy":"accelerator-only"}"#
        let npu = try decoder.decode(WorkerInfo.self, from: Data(raw.utf8))
        #expect(npu.device == "NPU")
        #expect(npu.executionPolicy == "accelerator-only")
        let gpu = WorkerInfo(model: npu.model, revision: npu.revision, runtime: "llama.cpp-vectors2", dtype: "q8_0",
                             dim: 768, textOnly: true, loadSeconds: nil)
        #expect(npu.vectorSource != gpu.vectorSource)
    }
}
