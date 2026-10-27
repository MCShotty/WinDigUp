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
    @Test func cudaIsTheOnlyNvidiaPathAndDevicePinsDoNotAliasBackends() throws {
        let cuda = AcceleratorDevice(id: "CUDA0", backend: "cuda", name: "RTX 2060", vendorID: 0x10de,
                                     stableID: "GPU-fixture", computeCapability: 75, driverVersion: 12090)
        #expect(Acceleration.nvidiaCUDA.accepts(cuda))
        #expect(!Acceleration.vulkan.accepts(cuda))
        #expect(!Acceleration.amdVulkan.accepts(cuda))
        #expect(cuda.matches("GPU-fixture"))
        #expect(!cuda.matches("Vulkan0"))
        var old = cuda; old.computeCapability = 61
        #expect(!Acceleration.nvidiaCUDA.accepts(old))
        old = cuda; old.driverVersion = 12080
        #expect(!Acceleration.nvidiaCUDA.accepts(old))
        old = cuda; old.computeCapability = 121
        #expect(!Acceleration.nvidiaCUDA.accepts(old))
        for capability in [75, 86, 89, 120] {
            old = cuda; old.computeCapability = capability
            #expect(Acceleration.nvidiaCUDA.accepts(old))
        }
        var bypass = cuda; bypass.backend = "vulkan"
        #expect(!Acceleration.vulkan.accepts(bypass))
        #expect(!Acceleration.amdVulkan.accepts(bypass))
        #expect(throws: WorkerError.self) { try Acceleration.selected(environment: ["DIGUP_ACCELERATOR": "nvidia-vulkan"]) }
        let amd = AcceleratorDevice(id: "Vulkan1", backend: "vulkan", name: "RX 5700 XT", vendorID: 0x1002)
        #expect(Acceleration.amdVulkan.accepts(amd)); #expect(Acceleration.vulkan.accepts(amd))
    }

    @Test func unsafeCudaOverridesAndAmbiguousMigrationBlockInference() throws {
        for extra in [["GGML_CUDA_ENABLE_UNIFIED_MEMORY":"1"], ["GGML_CUDA_ENABLE_UNIFIED_MEMORY":"0"],
                      ["GGML_CUDA_CUBLAS_COMPUTE_TYPE":"fp16"], ["DIGUP_GPU_SELECTION_REQUIRED":"1"],
                      ["DIGUP_ACCELERATOR_DISCOVERY_PENDING":"1"]] {
            #expect(throws: WorkerError.self) { try Acceleration.requireInferenceReady(environment: extra.merging(["DIGUP_ACCELERATOR":"nvidia-cuda"]) { a,_ in a }) }
        }
        try Acceleration.requireInferenceReady(environment: ["DIGUP_ACCELERATOR":"nvidia-cuda", "GGML_CUDA_CUBLAS_COMPUTE_TYPE":"fp32"])
    }

    @Test func cudaIndexAndFingerprintsAreIsolatedWithoutChangingLegacyVectors() throws {
        let base = URL(fileURLWithPath: "/fixtures/nvidia-cuda")
        #expect(Acceleration.nvidiaCUDA.indexDirectory(base: base) == base.appendingPathComponent("nvidia-cuda"))
        #expect(Acceleration.vulkan.indexDirectory(base: base) == base)
        #expect(Acceleration.openvinoNPU.indexDirectory(base: base) == base.appendingPathComponent("openvino-npu"))
        func info(_ revision: String = "abcdefg111111", _ build: String = "build-a", _ precision: String = "cuda-fp32-v1") -> WorkerInfo {
            WorkerInfo(model: "model", revision: revision, runtime: "llama.cpp-vectors2", dtype: "q8_0", dim: 768,
                       textOnly: true, loadSeconds: nil, backend: "nvidia-cuda", precisionProfile: precision, buildIdentity: build)
        }
        let reference = info()
        for changed in [info("abcdefg222222"), info("abcdefg111111", "build-b"), info("abcdefg111111", "build-a", "precision-v2")] {
            #expect(changed.vectorSource != reference.vectorSource)
            #expect(ApplicationStore.fingerprint(info: changed, backend: "nvidia-cuda") != ApplicationStore.fingerprint(info: reference, backend: "nvidia-cuda"))
        }
        let legacy = WorkerInfo(model:"model", revision:"abcdefg111111",runtime:"llama.cpp-vectors2",dtype:"q8_0",dim:768,textOnly:true,loadSeconds:nil)
        #expect(legacy.vectorSource == "model@abcdefg llama.cpp-vectors2 q8_0")
        let encoded = try JSONSerialization.data(withJSONObject: reference.fields)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(WorkerInfo.self,from:encoded).buildIdentity == reference.buildIdentity)
    }

    @Test func cudaFailuresDescribeMemoryAndUnsupportedOperationsWithoutFallback() {
        #expect(Acceleration.cudaFailure(diagnostic: "CUDA error: out of memory", fallback: "failed").hasPrefix("insufficient_vram:"))
        #expect(Acceleration.cudaFailure(diagnostic: "CUBLAS_STATUS_ALLOC_FAILED", fallback: "failed").hasPrefix("insufficient_vram:"))
        #expect(Acceleration.cudaFailure(diagnostic: "accelerator-only: refusing CPU graph execution", fallback: "failed").hasPrefix("unsupported_operation:"))
        #expect(Acceleration.cudaFailure(diagnostic: "no kernel image is available for execution", fallback: "failed").hasPrefix("unsupported_operation:"))
        #expect(Acceleration.cudaFailure(diagnostic: "invalid model header", fallback: "failed") == "failed")
    }
    @Test func resourceProfilesOnlyReduceBackgroundAdmission() throws {
        for profile in ["balanced", "faster"] {
            for (jobs, expected) in [("0",3),("1",1),("2",2),("3",3)] {
                let environment = ["DIGUP_RESOURCE_PROFILE":profile, "DIGUP_GPU_JOBS":jobs, "DIGUP_ACCELERATOR":"amd-vulkan"]
                try Acceleration.requireInferenceReady(environment: environment)
                #expect(GPUAdmission.maximumBackgroundJobs(environment: environment) == expected)
            }
        }
        #expect(GPUAdmission.maximumBackgroundJobs(environment: ["DIGUP_ACCELERATOR":"amd-vulkan", "DIGUP_GPU_JOBS":"2"]) == 2)
        #expect(GPUAdmission.maximumBackgroundJobs(environment: ["DIGUP_RESOURCE_PROFILE":"quiet", "DIGUP_GPU_JOBS":"3"]) == 1)
        for backend in ["openvino-npu", "metal"] {
            #expect(GPUAdmission.maximumBackgroundJobs(environment: ["DIGUP_ACCELERATOR":backend, "DIGUP_RESOURCE_PROFILE":"faster", "DIGUP_GPU_JOBS":"3"]) == 1)
        }
        #expect(throws: WorkerError.self) {
            try Acceleration.requireInferenceReady(environment: ["DIGUP_RESOURCE_PROFILE":"unbounded"])
        }
    }

    @Test func intelGpuUsesExclusiveWorkerAndIndependentFullFingerprints() throws {
        let backend = try Acceleration.selected(environment: ["DIGUP_ACCELERATOR":"openvino-gpu"])
        #expect(backend.isOpenVINO)
        let base = URL(fileURLWithPath: "/fixtures/openvino-gpu")
        #expect(backend.indexDirectory(base: base) == base.appendingPathComponent("openvino-gpu"))
        func info(_ revision: String, _ build: String = "build-a", device: String = "GPU.0",
                  backend: String = "openvino-gpu") -> WorkerInfo {
            WorkerInfo(model:"model", revision:revision, runtime:"openvino-gpu-v1-bundle", dtype:"fp32-ir",
                       dim:768, textOnly:true, loadSeconds:nil, device:device, executionPolicy:"accelerator-only",
                       backend:backend, precisionProfile:"openvino-gpu-f32-v1", buildIdentity:build)
        }
        let reference = info("abcdefg1111111111111111111111111111111111")
        #expect(backend.acceptsOpenVINOReceipt(reference))
        #expect(!backend.acceptsOpenVINOReceipt(info(reference.revision, device:"CPU")))
        #expect(!backend.acceptsOpenVINOReceipt(info(reference.revision, device:"GPU.fake")))
        #expect(!backend.acceptsOpenVINOReceipt(info(reference.revision, device:"NPU", backend:"openvino-npu")))
        #expect(reference.vectorSource != info("abcdefg2222222222222222222222222222222222").vectorSource)
        #expect(reference.vectorSource != info(reference.revision, "build-b").vectorSource)
        #expect(GPUAdmission.maximumBackgroundJobs(environment:["DIGUP_ACCELERATOR":"openvino-gpu","DIGUP_GPU_JOBS":"3"]) == 1)
    }

}
