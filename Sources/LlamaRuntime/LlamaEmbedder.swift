import CLlama
import DigUpKit
import Foundation

/// EmbeddingGemma 2 on llama.cpp (Metal), in this process: the image and audio encoders (mtmd) feed the text model, and
/// its mean-pooled, L2-normalized output is the vector.
///
/// Inputs are framed as the reference (mlx-vlm, transformers) frames them: `<bos> text <eos>`,
/// `<bos> <|image> soft tokens <image|> <eos>` and the same for audio. The model is non-causal with no KV cache, so
/// each input, token ids and encoder rows together, goes through one `llama_process` call, as llama-server's mixed
/// batches do. Measured against mlx-vlm bf16: cosine ≥ 0.999 on text and images, 0.9998 on a 30 s audio window.
/// Audio past 30 s is dropped, as in the reference.
///
/// One thread at a time; `close()` frees the model (about 1 GB, or 0.25 GB text-only).
public final class LlamaEmbedder: Embedder, InferenceReporting {
    public static let budgets = [70, 140, 280, 560, 1120]

    /// Which vectors this pipeline makes (the model files, llama.cpp, the resizing here, the prompts). It changes only
    /// when the vectors do, and `ReferenceVectorTests` says when that is: every llama.cpp update must reproduce the
    /// reference vectors, or come with a new version here (then every index embeds again). Indexes record this, not the
    /// llama.cpp build, so an update that leaves the vectors alone keeps them (b11461 made version 1).
    public static let vectorVersion = 2 // pooling and L2 normalization now execute on the accelerator

    /// The llama.cpp release this was built with (`scripts/build-llama.sh`), for logs.
    public static let buildTag = LLAMA_BUILD_TAG

    /// What every LlamaEmbedder reports (its `vectorSource` goes into index fingerprints), known without loading it.
    public static let buildIdentity = LLAMA_BUILD_ID
    public static var modelInfo: WorkerInfo {
        let cuda = (try? Acceleration.selected()) == .nvidiaCUDA
        return WorkerInfo(model: "google/embeddinggemma-2", revision: LlamaModels.revision,
            runtime: "llama.cpp-vectors\(vectorVersion)", dtype: "text-q8_0+mmproj-q8_0", dim: 768,
            textOnly: false, loadSeconds: nil, backend: cuda ? "nvidia-cuda" : nil,
            precisionProfile: cuda ? Acceleration.cudaPrecision : nil, buildIdentity: cuda ? buildIdentity : nil)
    }

    public private(set) var info: WorkerInfo
    private var admission: GPUAdmission?
    private var residency: GPULease?
    private var warming = true
    private var operationDepth = 0
    public var inferenceActivity: InferenceActivity? { admission?.activity }
    public var onInferenceActivity: (@Sendable (InferenceActivity) -> Void)? { didSet { admission?.onActivity = onInferenceActivity } }
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private var batch: OpaquePointer?
    private let vocab: OpaquePointer?
    private let embeddingSize: Int   // 768: the output projection
    private let rowSize: Int         // the width of encoder rows fed to the text model
    private let maxTokens: Int
    private static let maxSequences = 16
    private var sequences: Int32 = 0  // in `batch`
    private var batchIsQuery = false
    private var tokens = 0            // in `batch`
    private var position: llama_pos = 0

    /// `textOnly`: just the text model (queries). `log`: where llama.cpp's warnings and errors go (stderr when nil).
    public init(models: LlamaModels, textOnly: Bool, log: URL? = nil, onActivity: (@Sendable (InferenceActivity)->Void)? = nil) throws {
        let started = Date()
        LlamaLog.shared.send(to: log)
        let acceleration = try Acceleration.selected()
        try Acceleration.requireInferenceReady()
        guard acceleration != .openvinoNPU else { throw WorkerError.failed("OpenVINO requires the NPU worker") }
        _ = Self.backend
        guard ggml_backend_accelerator_only(), ggml_backend_accelerator_policy_version() == 2 else {
            throw WorkerError.failed("The loaded ggml library does not enforce accelerator-only execution")
        }
        let device = try Self.selectDevice(acceleration)
        let deviceInfo = Self.describe(device)
        let deviceName = String(cString: ggml_backend_dev_description(device))
        let coordinated = acceleration == .vulkan || acceleration == .amdVulkan || acceleration == .nvidiaCUDA
        let stable = deviceInfo.map { $0.stableID.isEmpty ? $0.id : $0.stableID } ?? "unknown"
        let gate = coordinated ? try GPUAdmission(identity: acceleration.registry + "|" + stable) : nil
        self.admission = gate
        gate?.onActivity=onActivity
        let startup = try gate?.request(profile: textOnly ? "text512" : "multimodal2048",
            foreground: textOnly && ProcessInfo.processInfo.environment["DIGUP_INFERENCE_PRIORITY"] == "foreground")
        defer { startup?.finish() }
        let loading = try gate?.loading()
        defer { loading?.release() }
        if let gate {
            let (resident, others, queryResident) = try gate.resident(query:textOnly)
            self.residency = resident
            var free = 0, total = 0
            ggml_backend_dev_memory(device, &free, &total)
            var files:[URL]=[models.text]
            if !textOnly,let mediaFile=models.media{files.append(mediaFile)}
            var weights:Int64=0
            for file in files{
                let attributes=try? FileManager.default.attributesOfItem(atPath:file.path)
                let bytes=(attributes?[.size] as? NSNumber)?.int64Value ?? 0
                weights+=bytes
            }
            let minimum:Int64=536_870_912
            var reserve:Int64=max(minimum,weights*2)
            reserve+=268_435_456
            if !textOnly && !queryResident{reserve+=1_073_741_824}
            if ((total == 0 || free == 0) && others > 0) || total > 0 && free > 0 && Int64(free) < reserve {
                throw WorkerError.failed((others > 0 ? "capacity_limited: " : "insufficient_vram: ") +
                    "Not enough verified free GPU memory for another model context. Existing workers stay on the selected GPU.")
            }
        }
        guard textOnly || models.media != nil else {
            throw WorkerError.notFound("\(LlamaModels.mediaFile) (images and audio) isn't downloaded yet")
        }
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        modelParams.split_mode = LLAMA_SPLIT_MODE_NONE
        // Pin the text and both media encoders to the same physical device. Never pick another backend implicitly.
        var devices: [ggml_backend_dev_t?] = [device, nil]
        let loaded = devices.withUnsafeMutableBufferPointer { pinned -> OpaquePointer? in
            modelParams.devices = pinned.baseAddress
            return llama_model_load_from_file(models.text.path, modelParams)
        }
        guard let model = loaded else {
            throw WorkerError.failed(LlamaLog.shared.failure("can't load the complete model on \(deviceName); CPU fallback is disabled"))
        }
        // One input must fit one micro-batch: 2048 tokens (the reference's cut), which also holds a 1120-token image or
        // a 750-token 30 s clip. Queries are short, so the query encoder reserves less and cuts at 512.
        let maxTokens = textOnly ? 512 : 2048
        var params = llama_context_default_params()
        params.n_ctx = UInt32(maxTokens)
        params.n_batch = UInt32(maxTokens)
        params.n_ubatch = UInt32(maxTokens)
        params.n_seq_max = UInt32(Self.maxSequences)
        params.kv_unified = true   // each input may use the whole context, as in llama-embedding
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_MEAN
        params.op_offload = true
        params.offload_kqv = true
        if acceleration == .nvidiaCUDA {
            params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED
            params.type_k = GGML_TYPE_F32
            params.type_v = GGML_TYPE_F32
        }
        #if !os(macOS)
        params.n_threads = Self.threads
        params.n_threads_batch = Self.threads
        #endif
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw WorkerError.failed(LlamaLog.shared.failure("can't create a llama.cpp context"))
        }
        var media: OpaquePointer?
        if let mediaFile = models.media, !textOnly {
            var mediaParams = mtmd_context_params_default()
            mediaParams.use_gpu = true
            mediaParams.device = device
            if acceleration == .nvidiaCUDA { mediaParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED }
            mediaParams.print_timings = false
            mediaParams.warmup = true
            mediaParams.image_min_tokens = 1      // never rescale: images arrive at their final size (ImageSizing)
            mediaParams.image_max_tokens = 1120
            #if !os(macOS)
            mediaParams.n_threads = Self.threads
            #endif
            media = mtmd_init_from_file(mediaFile.path, model, mediaParams)
            if media == nil {
                llama_free(context)
                llama_model_free(model)
                throw WorkerError.failed(LlamaLog.shared.failure("can't load \(mediaFile.path)"))
            }
        }
        self.model = model
        self.context = context
        self.media = media
        batch = llama_batch_ext_init(context)
        vocab = llama_model_get_vocab(model)
        embeddingSize = Int(llama_model_n_embd_out(model))
        rowSize = Int(llama_model_n_embd_inp(model))
        self.maxTokens = maxTokens
        let known = Self.modelInfo
        info = WorkerInfo(model: known.model, revision: known.revision, runtime: known.runtime, dtype: known.dtype,
                          dim: embeddingSize, textOnly: textOnly, loadSeconds: nil,
                          device: deviceName, executionPolicy: "accelerator-only", backend: acceleration.rawValue,
                          deviceId: deviceInfo?.stableID, driverVersion: deviceInfo?.driverVersion,
                          runtimeVersion: deviceInfo?.runtimeVersion, precisionProfile: known.precisionProfile,
                          buildIdentity: known.buildIdentity)
        // The first calls build the Metal pipelines: pay that now (the panel is opening).
        do {
            for _ in 0..<2 { _ = try embedTexts([Prompts.query("warm up")]) }
        } catch {
            close()
            throw error
        }
        warming = false
        let seconds = (Date().timeIntervalSince(started) * 100).rounded() / 100
        info = WorkerInfo(model: info.model, revision: info.revision, runtime: info.runtime, dtype: info.dtype,
                          dim: info.dim, textOnly: textOnly, loadSeconds: seconds,
                          device: deviceName, executionPolicy: "accelerator-only", backend: info.backend,
                          deviceId: info.deviceId, driverVersion: info.driverVersion, runtimeVersion: info.runtimeVersion,
                          precisionProfile: info.precisionProfile, buildIdentity: info.buildIdentity)
        LlamaLog.shared.line("accelerator-only: \(deviceName); text, vision, audio, pooling and normalization on GPU")
        LlamaLog.shared.line("ready in \(seconds) s (\(textOnly ? "text-only" : "full"), llama.cpp \(Self.buildTag), "
                             + "vectors \(Self.vectorVersion))")
    }

    deinit { close() }

    public func close() {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (batch, media, context, model) = (nil, nil, nil, nil)
        residency?.release(); residency = nil
    }

    // MARK: Embedder

    public func embedTexts(_ texts: [String]) throws -> [[Float]] {
        reset()
        var vectors: [[Float]] = []
        for text in texts {
            let tokens = tokenize(text)
            if sequences == Self.maxSequences || self.tokens + tokens.count > maxTokens { vectors += try run() }
            if sequences == 0 { batchIsQuery = text.hasPrefix(Prompts.query("")) || text.hasPrefix(Prompts.codeQuery("")) }
            begin()
            for token in tokens { try add(token: token) }
        }
        if sequences > 0 { vectors += try run() }
        return vectors
    }

    public func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        guard media != nil else { throw WorkerError.failed("this embedder was started text-only") }
        guard Self.budgets.contains(budget) else { throw WorkerError.failed("budget must be one of \(Self.budgets)") }
        return paths.map { path in embedding { try embedMedia(path, image: true, budget: budget) } }
    }

    public func embedAudio(_ paths: [String]) throws -> [Embedding] {
        guard media != nil else { throw WorkerError.failed("this embedder was started text-only") }
        return paths.map { path in embedding { try embedMedia(path, image: false, budget: 0) } }
    }

    /// One file's vector, or why it has none (an unreadable file must not sink its neighbours).
    private func embedding(_ make: () throws -> [Float]) -> Embedding {
        do {
            return Embedding(vector: try make(), error: nil)
        } catch {
            return Embedding(vector: nil, error: String("\(error)".prefix(300)))
        }
    }

    // MARK: Media

    private func embedMedia(_ path: String, image: Bool, budget: Int) throws -> [Float] {
        let operation = try beginOperation(foreground: false)
        defer { operationDepth -= 1; operation?.finish(inputs: 1) }
        let bitmap = try load(path, image: image, budget: budget)
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let status = String(cString: mtmd_default_marker()).withCString { marker in
            var text = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &text, &bitmaps, 1)
        }
        guard status == 0 else { throw LlamaError("can't tokenize \(path) (\(status))") }
        reset()
        begin()
        for index in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                guard let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                for i in 0..<count { try add(token: tokens[i]) }
            } else {
                guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media) else {
                    throw LlamaError(LlamaLog.shared.failure("the encoder failed on \(path)"))
                }
                try add(rows: rows, count: mtmd_input_chunk_get_n_tokens(chunk))
            }
        }
        return try run()[0]
    }

    /// Reads an image or audio file with mtmd's helpers (stb_image, miniaudio at 16 kHz), resizes images for `budget`
    /// and cuts audio at 30 s. The caller frees the bitmap.
    private func load(_ path: String, image: Bool, budget: Int) throws -> OpaquePointer {
        #if os(Windows)
        // mtmd opens a path with fopen, which on Windows reads it in the ANSI code page (a temp folder under a Bengali
        // user name wouldn't open), so the bytes go in instead: its file variant reads them into a buffer the same way.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let wrapper = bytes.withUnsafeBytes { buffer in
            mtmd_helper_bitmap_init_from_buf(media, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, false,
                                             mtmd_helper_init_opt_default())
        }
        #else
        let wrapper = mtmd_helper_bitmap_init_from_file(media, path, false, mtmd_helper_init_opt_default())
        #endif
        if let video = wrapper.video_ctx {
            if let bitmap = wrapper.bitmap { mtmd_bitmap_free(bitmap) }
            mtmd_helper_video_free(video)
            throw LlamaError("video goes in as frames and sound, not as a file: \(path)")
        }
        guard let bitmap = wrapper.bitmap else { throw LlamaError("can't read \(path)") }
        guard mtmd_bitmap_is_audio(bitmap) != image else {
            mtmd_bitmap_free(bitmap)
            throw LlamaError("not \(image ? "an image" : "audio"): \(path)")
        }
        if image {
            let width = Int(mtmd_bitmap_get_nx(bitmap)), height = Int(mtmd_bitmap_get_ny(bitmap))
            guard let target = ImageSizing.targetSize(height: height, width: width, budget: budget) else {
                mtmd_bitmap_free(bitmap)
                throw LlamaError("image too thin to embed: \(path)")
            }
            guard target != (height, width) else { return bitmap }
            defer { mtmd_bitmap_free(bitmap) }
            let pixels = ImageSizing.resizeBicubic(mtmd_bitmap_get_data(bitmap), width: width, height: height,
                                                   toWidth: target.width, toHeight: target.height)
            guard let resized = mtmd_bitmap_init(UInt32(target.width), UInt32(target.height), pixels) else {
                throw LlamaError("can't resize \(path)")
            }
            return resized
        }
        let samples = mtmd_bitmap_get_n_bytes(bitmap) / MemoryLayout<Float>.size
        let limit = 30 * Int(mtmd_get_audio_sample_rate(media))
        guard samples > limit else { return bitmap }
        defer { mtmd_bitmap_free(bitmap) }
        let prefix = mtmd_bitmap_get_data(bitmap).withMemoryRebound(to: Float.self, capacity: limit) {
            mtmd_bitmap_init_from_audio(limit, $0)
        }
        guard let prefix else { throw LlamaError("can't cut \(path) at 30 s") }
        return prefix
    }

    // MARK: Text model

    /// `<bos> text <eos>`, cut to `maxTokens` the way transformers cuts (keeping both special tokens).
    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        }
        tokens.removeLast(tokens.count - Int(max(count, 0)))
        if tokens.count > maxTokens {
            tokens = Array(tokens[0..<(maxTokens - 1)]) + [llama_vocab_eos(vocab)]
        }
        return tokens
    }

    /// Starts the next input in the batch (each input is its own sequence).
    private func begin() {
        sequences += 1
        position = 0
    }

    /// Drops everything added so far, including an input that failed halfway.
    private func reset() {
        LlamaLog.shared.clearFailure()
        llama_batch_ext_clear(batch)
        sequences = 0
        tokens = 0
    }

    private func add(token: llama_token) throws {
        try place(llama_batch_ext_add_token(batch, sequences - 1, token))
    }

    private func add(rows: UnsafeMutablePointer<Float>, count: Int) throws {
        for row in 0..<count {
            let embd = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)   // copied by the batch
            try place(llama_batch_ext_add_embd(batch, sequences - 1, embd))
        }
    }

    private func place(_ index: Int32) throws {
        guard index >= 0 else { throw LlamaError("batch full (\(index))") }
        var pos: [llama_pos] = [position, 0, 0, 0]
        guard llama_batch_ext_set_pos(batch, index, &pos), llama_batch_ext_set_output_embd(batch, index, true) else {
            throw LlamaError("can't place token \(index)")
        }
        position += 1
        tokens += 1
    }

    /// Runs the text model over the batch and returns one L2-normalized vector per input, in order.
    private func run() throws -> [[Float]] {
        let count = Int(sequences)
        let operation = try beginOperation(foreground: batchIsQuery)
        defer { operationDepth -= 1; operation?.finish(inputs: count) }
        defer { reset() }
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else { throw WorkerError.failed(LlamaLog.shared.failure("llama_process failed (\(status))")) }
        return try (0..<sequences).map { sequence in
            guard let pooled = llama_get_embeddings_seq(context, sequence) else {
                throw WorkerError.failed("no pooled embedding for input \(sequence)")
            }
            let vector = Array(UnsafeBufferPointer(start: pooled, count: embeddingSize))
            // Validate the device result; never repair or normalize an invalid vector on the host.
            let normSquared = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
            guard vector.allSatisfy(\.isFinite), abs(normSquared - 1) < 0.005 else {
                throw WorkerError.failed("accelerator returned an invalid embedding")
            }
            return vector
        }
    }

    private func beginOperation(foreground: Bool) throws -> GPUAdmission.Operation? {
        let operation = !warming && operationDepth == 0
            ? try admission?.request(profile: maxTokens == 512 ? "text512" : "multimodal2048", foreground: foreground) : nil
        operationDepth += 1
        return operation
    }

    private static func describe(_ device: ggml_backend_dev_t) -> AcceleratorDevice? {
        let registry = String(cString: ggml_backend_reg_name(ggml_backend_dev_backend_reg(device))).lowercased()
        let type = ggml_backend_dev_type(device)
        var native = ggml_accelerator_device_info()
        let hasInfo = ggml_backend_dev_accelerator_info(device, &native)
        if registry != "metal" && (!hasInfo || native.policy_version != 2) { return nil }
        let stable = withUnsafePointer(to: &native.stable_id) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 96) { String(cString: $0) }
        }
        return AcceleratorDevice(id: String(cString: ggml_backend_dev_name(device)), backend: registry,
            name: String(cString: ggml_backend_dev_description(device)), vendorID: native.vendor_id, stableID: stable,
            hardware: type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU,
            computeCapability: native.compute_capability > 0 ? Int(native.compute_capability) : nil,
            driverVersion: native.driver_version > 0 ? Int(native.driver_version) : nil,
            runtimeVersion: native.runtime_version > 0 ? Int(native.runtime_version) : nil)
    }

    private static func selectDevice(_ acceleration: Acceleration) throws -> ggml_backend_dev_t {
        let requested = ProcessInfo.processInfo.environment["DIGUP_GPU"]
        if acceleration == .nvidiaCUDA, requested?.hasPrefix("Vulkan") == true {
            throw WorkerError.failed("A Vulkan device identifier cannot select CUDA. Re-select the GPU in Settings.")
        }
        for preferred in [GGML_BACKEND_DEVICE_TYPE_GPU, GGML_BACKEND_DEVICE_TYPE_IGPU] {
            for index in 0..<ggml_backend_dev_count() {
                guard let device = ggml_backend_dev_get(index), ggml_backend_dev_type(device) == preferred,
                      let value = describe(device), acceleration.accepts(value), value.matches(requested) else { continue }
                return device
            }
        }
        if acceleration == .nvidiaCUDA {
            for index in 0..<ggml_backend_dev_count() {
                guard let device = ggml_backend_dev_get(index), let value = describe(device),
                      value.backend == "cuda", value.matches(requested) else { continue }
                if !Acceleration.cudaComputeCapabilities.contains(value.computeCapability ?? 0) {
                    throw WorkerError.failed("Unsupported CUDA GPU: \(value.name) (SM \(value.computeCapability ?? 0)). This build targets RTX 20/30/40/50-series (SM 75/86/89/120).")
                }
                if (value.driverVersion ?? 0) < 12090 {
                    throw WorkerError.failed("Insufficient NVIDIA driver for \(value.name). Install driver 576.57 or newer (CUDA driver API 12.9 or newer).")
                }
            }
        }
        let hint = acceleration == .nvidiaCUDA
            ? "CUDA requires RTX 20-series or newer and NVIDIA driver 576.57 or newer. Check the CUDA runtime and device selection in Settings."
            : "NVIDIA cannot use Vulkan. AMD requires a current Vulkan driver and RDNA1/RX 5000 or newer."
        throw WorkerError.failed("No compatible \(acceleration.rawValue) hardware GPU\(requested.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? "") found. \(hint) CPU fallback is disabled.")
    }

    public static func verifyDevice() throws -> AcceleratorDevice {
        let selected = try Acceleration.selected()
        try Acceleration.requireInferenceReady()
        guard selected != .openvinoNPU else { throw WorkerError.failed("Probe NPU through its model worker") }
        _ = backend
        guard ggml_backend_accelerator_only(), ggml_backend_accelerator_policy_version() == 2 else {
            throw WorkerError.failed("Unverified native accelerator policy")
        }
        let device = try selectDevice(selected)
        guard let value = describe(device) else { throw WorkerError.failed("Device metadata is unavailable") }
        return value
    }

    public static func verifyGPU() throws -> String { try verifyDevice().name }

    /// No weights or inference. CUDA dependencies are dynamically loaded and cannot prevent the GUI from starting.
    public static func deviceInventory() throws -> [String: Any] {
        _ = backend
        guard ggml_backend_accelerator_only(), ggml_backend_accelerator_policy_version() == 2 else {
            throw WorkerError.failed("The loaded native libraries do not implement accelerator policy 2")
        }
        var devices: [[String: Any]] = []
        for index in 0..<ggml_backend_dev_count() {
            guard let device = ggml_backend_dev_get(index), let value = describe(device) else { continue }
            let acceleration: Acceleration = value.backend == "cuda" ? .nvidiaCUDA : value.backend == "metal" ? .metal : .vulkan
            let available = acceleration.accepts(value)
            var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            fields["available"] = available
            if !available {
                if value.backend == "cuda", !Acceleration.cudaComputeCapabilities.contains(value.computeCapability ?? 0) {
                    fields["errorCode"] = "unsupported_device"; fields["message"] = "This CUDA build supports RTX 20/30/40/50-series (SM 75/86/89/120)."
                } else if value.backend == "cuda", (value.driverVersion ?? 0) < 12090 {
                    fields["errorCode"] = "insufficient_driver"; fields["message"] = "Install NVIDIA driver 576.57 or newer (CUDA driver API 12.9 or newer)."
                } else { fields["errorCode"] = "unsupported_device"; fields["message"] = "Unsupported hardware device" }
            }
            devices.append(fields)
        }
        let registers = (0..<ggml_backend_reg_count()).map { String(cString: ggml_backend_reg_name(ggml_backend_reg_get($0))).lowercased() }
        let folder = Bundle.main.executableURL?.deletingLastPathComponent()
        var backends: [[String: Any]] = []
        for name in ["cuda", "vulkan"] {
            let ready = devices.contains { $0["backend"] as? String == name && $0["available"] as? Bool == true }
            var fields: [String: Any] = ["backend": name, "state": ready ? "available" : "unavailable"]
            if !ready {
                var code = registers.contains(name) ? "device_unavailable" : "backend_unavailable"
                var message = name == "cuda" ? "CUDA is unavailable. Check NVIDIA driver 576.57 or newer and the app-local CUDA runtime." : "No supported non-NVIDIA Vulkan GPU is available."
                if let unavailable = devices.first(where: { $0["backend"] as? String == name && $0["errorCode"] != nil }) {
                    code = unavailable["errorCode"] as? String ?? code; message = unavailable["message"] as? String ?? message
                }
                #if os(Windows)
                if name == "cuda" {
                    let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
                    if !FileManager.default.fileExists(atPath: system + "\\System32\\nvcuda.dll") {
                        code = "driver_missing"; message = "Install an NVIDIA driver supporting CUDA 12.9.1 (576.57 or newer)."
                    } else if let folder, ["cudart64_12.dll", "cublas64_12.dll", "cublasLt64_12.dll", "ggml-cuda.dll"].contains(where: { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
                        code = "runtime_missing"; message = "The packaged CUDA runtime is incomplete. Reinstall WinDigUp."
                    }
                }
                #endif
                fields["errorCode"] = code; fields["message"] = message
            }
            backends.append(fields)
        }
        _ = folder
        return ["schemaVersion": 1, "probeOnly": true, "devices": devices, "backends": backends,
                "policyVersion": 2, "buildIdentity": buildIdentity, "precisionProfile": Acceleration.cudaPrecision]
    }

    /// llama.cpp's process-wide setup, once.
    private static let backend: Void = {
        llama_log_set(LlamaLog.callback, LlamaLog.userData)
        mtmd_helper_log_set(LlamaLog.callback, LlamaLog.userData)
        #if !os(macOS)
        loadBackends()
        #endif
        llama_backend_init()
    }()

    #if !os(macOS)
    /// Host preprocessing/orchestration threads. The native execution guard disallows CPU model graph computation.
    static let threads: Int32 = {
        let chosen = ProcessInfo.processInfo.environment["DIGUP_THREADS"].flatMap(Int32.init)
        return max(1, chosen ?? Int32(min(ProcessInfo.processInfo.activeProcessorCount, 8)))
    }()

    /// On Linux and Windows ggml's backends are shared libraries (GGML_BACKEND_DL, scripts/build-llama.sh): the CPU
    /// storage variants, CUDA for NVIDIA and Vulkan for non-NVIDIA hardware. Selection always pins the requested registry/device.
    private static func loadBackends() {
        let environment = ProcessInfo.processInfo.environment
        var folders: [String] = []
        if let chosen = environment["DIGUP_BACKENDS"], !chosen.isEmpty { folders.append(chosen) }
        if let executable = Bundle.main.executableURL { folders.append(executable.deletingLastPathComponent().path) }
        for folder in folders {
            ggml_backend_load_all_from_path(folder)
        }
        ggml_backend_load_all()
        LlamaLog.shared.line("backends: " + (0..<ggml_backend_reg_count()).map {
            String(cString: ggml_backend_reg_name(ggml_backend_reg_get($0)))
        }.joined(separator: ", ") + " (accelerator-only)")
    }
    #endif
}

/// A problem with one input (it gets no vector; its neighbours go on).
struct LlamaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// llama.cpp's log is process-wide: warnings and errors go to one file (or stderr), the rest is dropped (it logs a lot
/// at load time).
final class LlamaLog: @unchecked Sendable {
    static let shared = LlamaLog()
    nonisolated(unsafe) static let userData = Unmanaged.passUnretained(shared).toOpaque()
    nonisolated(unsafe) static let callback: ggml_log_callback = { level, text, userData in
        guard let text, let userData else { return }
        Unmanaged<LlamaLog>.fromOpaque(userData).takeUnretainedValue().write(level, String(cString: text))
    }

    private let lock = NSLock()
    private var file: FileHandle?             // nil: stderr
    private var level = GGML_LOG_LEVEL_INFO   // CONT continues the previous message, at its level
    private var recent = ""

    func clearFailure() { lock.withLock { recent = "" } }

    func failure(_ fallback: String) -> String {
        guard (try? Acceleration.selected()) == .nvidiaCUDA else { return fallback }
        return lock.withLock { Acceleration.cudaFailure(diagnostic: recent, fallback: fallback) }
    }

    func send(to url: URL?) {
        lock.withLock {
            try? file?.close()
            file = nil
            recent = ""
            guard let url else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            file = try? FileHandle(forWritingTo: url)
            file?.seekToEndOfFile()
        }
    }

    /// One of our own lines.
    func line(_ message: String) {
        lock.withLock { (file ?? .standardError).write(Data("[llama.cpp worker] \(message)\n".utf8)) }
    }

    private func write(_ level: ggml_log_level, _ text: String) {
        lock.withLock {
            if level != GGML_LOG_LEVEL_CONT { self.level = level }
            guard self.level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
            recent = String((recent + text).suffix(16_384))
            (file ?? .standardError).write(Data(text.utf8))
        }
    }
}
