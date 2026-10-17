import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// What the embedding runtime reports about its model; part of the index fingerprint.
public struct WorkerInfo: Codable, Sendable {
    public let model: String
    public let revision: String
    public let runtime: String
    public let dtype: String
    public let dim: Int
    public let textOnly: Bool
    public let loadSeconds: Double?
    public let device: String?
    public let executionPolicy: String?
    public let backend: String?
    public let deviceId: String?
    public let driverVersion: Int?
    public let runtimeVersion: Int?
    public let precisionProfile: String?
    public let buildIdentity: String?

    public init(
        model: String, revision: String, runtime: String, dtype: String, dim: Int, textOnly: Bool,
        loadSeconds: Double?, device: String? = nil, executionPolicy: String? = nil,
        backend: String? = nil, deviceId: String? = nil, driverVersion: Int? = nil, runtimeVersion: Int? = nil,
        precisionProfile: String? = nil, buildIdentity: String? = nil
    ) {
        self.model = model
        self.revision = revision
        self.runtime = runtime
        self.dtype = dtype
        self.dim = dim
        self.textOnly = textOnly
        self.loadSeconds = loadSeconds
        self.device = device
        self.executionPolicy = executionPolicy
        self.backend = backend
        self.deviceId = deviceId
        self.driverVersion = driverVersion
        self.runtimeVersion = runtimeVersion
        self.precisionProfile = precisionProfile
        self.buildIdentity = buildIdentity
    }

    /// Vectors from different models, revisions, runtimes or precisions must never share an index.
    public var vectorSource: String {
        if backend == "nvidia-cuda" {
            return "cuda-v1:"
                + [
                    model, revision, runtime, dtype, String(dim), backend ?? "", precisionProfile ?? "",
                    buildIdentity ?? "",
                    "query-text512-v1;documents-multimodal2048-v1", Prompts.query(""), Prompts.codeQuery(""),
                    Prompts.document(title: "{title}", text: "{text}"),
                ]
                .map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        }
        return "\(model)@\(revision.prefix(7)) \(runtime) \(dtype)"
    }

    public var fields: [String: Any] {
        var value: [String: Any] = [
            "model": model, "revision": revision, "runtime": runtime, "dtype": dtype,
            "dim": dim, "text_only": textOnly, "load_seconds": loadSeconds ?? 0,
            "device": device ?? "", "execution_policy": executionPolicy ?? "",
        ]
        value["backend"] = backend
        value["device_id"] = deviceId
        value["driver_version"] = driverVersion
        value["runtime_version"] = runtimeVersion
        value["precision_profile"] = precisionProfile
        value["build_identity"] = buildIdentity
        return value
    }
}

/// The four calls every embedding runtime answers: the model linked into this process (llama.cpp, `LlamaRuntime`), or
/// a worker process speaking JSON lines (`EmbeddingWorker`: the mlx-vlm reference, or `digup worker`).
/// One thread at a time.
public protocol Embedder: AnyObject {
    var info: WorkerInfo { get }
    func embedTexts(_ texts: [String]) throws -> [[Float]]
    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding]
    func embedAudio(_ paths: [String]) throws -> [Embedding]
    /// Frees the model. Safe to call twice.
    func close()
}

/// How to start a worker process that speaks the JSON-lines protocol (see `EmbeddingWorker`).
public struct WorkerConfig: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String] = [:]
    public var log: URL?
    /// The worker process's priority: user-initiated for the query encoder (App Nap and efficiency cores can slow
    /// a search from 125 to 650 ms), utility for background indexing.
    public var qos: QualityOfService = .default
    public var onInferenceActivity: (@Sendable (InferenceActivity) -> Void)?
    public var onStart: (@Sendable (Process) -> Void)?
    public var startupTimeout: TimeInterval?
    public var requestTimeout: TimeInterval?

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The bundled helper (`digup worker`): EmbeddingGemma 2 on llama.cpp, what the app ships with.
    public static func helper(_ executable: URL) -> WorkerConfig {
        WorkerConfig(executable: executable, arguments: ["worker"])
    }

    /// The Python mlx-vlm worker in `folder` (the repo's `worker/`): the reference runtime for evals.
    public static func python(_ folder: URL) throws -> WorkerConfig {
        let python = folder.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw WorkerError.notFound("worker environment missing; run: uv sync --project \(folder.path)")
        }
        let model = "google/embeddinggemma-2"
        var config = WorkerConfig(
            executable: python,
            arguments: [
                "-I", folder.appendingPathComponent("digup_worker.py").path, "--model", model,
            ])
        config.environment["TOKENIZERS_PARALLELISM"] = "false"
        // Once the model is on disk, nothing should touch the network.
        if EmbeddingWorker.modelIsCached(model) { config.environment["HF_HUB_OFFLINE"] = "1" }
        return config
    }

    /// The verified OpenVINO NPU worker, when explicitly selected. Other production worker overrides are disabled.
    public static func fromEnvironment() throws -> WorkerConfig? {
        let acceleration = try Acceleration.selected()
        guard acceleration == .openvinoNPU else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let python = env["DIGUP_OPENVINO_PYTHON"], !python.isEmpty,
            let models = env["DIGUP_OPENVINO_MODELS"], !models.isEmpty
        else {
            throw WorkerError.notFound(
                "OpenVINO NPU needs a Python environment and exported model bundle in Settings → General.")
        }
        guard
            let script = env["DIGUP_OPENVINO_WORKER"].map({ URL(fileURLWithPath: $0) })
                ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
                    "openvino/digup_openvino.py")
        else {
            throw WorkerError.notFound("Cannot locate the bundled OpenVINO worker; set DIGUP_OPENVINO_WORKER")
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw WorkerError.notFound("OpenVINO worker missing at \(script.path)")
        }
        var config = WorkerConfig(
            executable: URL(fileURLWithPath: python),
            arguments: ["-I", script.path, "--models", models])
        config.environment = ["HF_HUB_OFFLINE": "1", "TOKENIZERS_PARALLELISM": "false", "PYTHONUTF8": "1"]
        return config
    }
}

public enum WorkerError: Error, CustomStringConvertible {
    case notFound(String)
    case failed(String)
    case died(String)

    public var description: String {
        switch self {
        case .notFound(let why): "worker not found: \(why)"
        case .failed(let why): "worker error: \(why)"
        case .died(let why): "worker stopped: \(why)"
        }
    }
}

/// One embedding (or why the file couldn't be embedded).
public struct Embedding: Sendable {
    public let vector: [Float]?
    public let error: String?

    public init(vector: [Float]?, error: String?) {
        self.vector = vector
        self.error = error
    }
}

/// Talks to a worker process over stdin/stdout, one JSON line each way (the protocol is in
/// `worker/digup_worker.py`). The model lives in that separate process so its memory goes back to the OS when it
/// exits.
public final class EmbeddingWorker: Embedder, InferenceReporting {
    public private(set) var info = WorkerInfo(
        model: "", revision: "", runtime: "", dtype: "", dim: Vectors.dimension,
        textOnly: false, loadSeconds: nil)  // until the worker reports in
    private let activityLock=NSLock()
    private var lastInference: InferenceActivity?
    public var inferenceActivity: InferenceActivity? { activityLock.withLock { lastInference } }
    private let onInferenceActivity: (@Sendable (InferenceActivity) -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private let log: URL?
    private let requestTimeout: TimeInterval?
    private let deadline = WorkerDeadline()
    private var failed = false

    private struct Request: Encodable {
        let id: Int
        let op: String
        let inputs: [String]?
        let budget: Int?
    }

    private struct Reply: Decodable {
        let event: String?
        let activity: InferenceActivity?
        let id: Int?
        let ok: Bool?
        let ready: Bool?
        let error: String?
        let dim: Int?
        let vectors: String?
        let errors: [String?]?
        let info: WorkerInfo?
    }

    public init(_ config: WorkerConfig, textOnly: Bool) throws {
        onInferenceActivity = config.onInferenceActivity
        requestTimeout = config.requestTimeout
        process.executableURL = config.executable
        process.qualityOfService = config.qos
        process.arguments = config.arguments + (textOnly ? ["--text-only"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging(config.environment) { $1 }
        process.standardInput = input
        process.standardOutput = output
        log = config.log
        if let log = config.log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: log)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        config.onStart?(process)
        let ready = try limited(config.startupTimeout, "Query worker startup") { try readReply() }
        guard ready.ready == true, let info = ready.info else {
            failed = true
            throw WorkerError.failed(ready.error ?? "didn't start\(logTail())")
        }
        self.info = info
    }

    deinit { close() }

    /// Shutdown only: interrupt a blocked child read before draining the encoder owner.
    public func interrupt() {
        WorkerDeadline.stop(process)
    }
    /// The startup callback may need to stop its owned child before the ready handshake has completed.
    public static func interrupt(_ process: Process) { WorkerDeadline.stop(process) }

    public func embedTexts(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try send("text", texts, budget: nil).map { $0.vector ?? [] }
    }

    public func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        guard !paths.isEmpty else { return [] }
        return try send("image", paths, budget: budget)
    }

    public func embedAudio(_ paths: [String]) throws -> [Embedding] {
        guard !paths.isEmpty else { return [] }
        return try send("audio", paths, budget: nil)
    }

    public func close() {
        if failed { WorkerDeadline.stop(process);try? input.fileHandleForWriting.close();return }
        guard process.isRunning else { return }
        if let line = try? JSONEncoder().encode(Request(id: 0, op: "quit", inputs: nil, budget: nil)) {
            try? input.fileHandleForWriting.write(contentsOf: line + [0x0A])
        }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        WorkerDeadline.stop(process)
    }

    private func send(_ op: String, _ inputs: [String], budget: Int?) throws -> [Embedding] {
        let id = nextID
        nextID += 1
        let line = try JSONEncoder().encode(Request(id: id, op: op, inputs: inputs, budget: budget))
        return try limited(requestTimeout, "Query encoding") {
            do {
                try input.fileHandleForWriting.write(contentsOf: line + [0x0A])
            } catch {
                throw WorkerError.died("can't write to the worker\(logTail())")
            }
            let reply = try readReply()
            guard reply.id == id else { throw WorkerError.failed("reply out of order") }
            guard reply.ok == true, let encoded = reply.vectors, let data = Data(base64Encoded: encoded) else {
                throw WorkerError.failed(reply.error ?? "no vectors")
            }
            let dim = reply.dim ?? Vectors.dimension
            var floats = [Float](repeating: 0, count: data.count / 4)
            _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            guard floats.count == dim * inputs.count else { throw WorkerError.failed("got \(floats.count) floats") }
            let errors = reply.errors ?? []
            return inputs.indices.map { index in
                let error = index < errors.count ? errors[index] : nil
                return Embedding(
                    vector: error == nil ? Array(floats[(index * dim)..<((index + 1) * dim)]) : nil, error: error)
            }
        }
    }

    private func limited<T>(_ seconds: TimeInterval?, _ stage: String, _ action: () throws -> T) throws -> T {
        deadline.arm(seconds, process: process)
        do {
            let value = try action()
            if deadline.finish() {
                failed = true
                throw WorkerError.failed(
                    "\(stage) timed out. Check Activity and retry explicitly; CPU fallback is disabled.")
            }
            return value
        } catch {
            failed = true
            if deadline.finish() {
                throw WorkerError.failed(
                    "\(stage) timed out. Check Activity and retry explicitly; CPU fallback is disabled.")
            }
            throw error
        }
    }

    private func readReply() throws -> Reply {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let reply=try decoder.decode(Reply.self, from: line)
                if reply.event=="inference_activity",let activity=reply.activity {
                    activityLock.withLock { lastInference=activity }
                    onInferenceActivity?(activity)
                    continue
                }
                return reply
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw WorkerError.died("exited\(logTail())") }
            buffer.append(chunk)
        }
    }

    private func logTail() -> String {
        guard let log, let file = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? file.close() }
        guard let end = try? file.seekToEnd() else { return "" }
        try? file.seek(toOffset: end > 32_768 ? end - 32_768 : 0)
        let text = String(decoding: (try? file.read(upToCount: 32_768)) ?? Data(), as: UTF8.self)
        let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n  ")
        return tail.isEmpty ? "" : "; worker log (\(log.path)):\n  \(tail)"
    }

    static func modelIsCached(_ model: String) -> Bool {
        if FileManager.default.fileExists(atPath: model) { return true }
        let folder = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let hub =
            ProcessInfo.processInfo.environment["HF_HUB_CACHE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub").path
        return FileManager.default.fileExists(atPath: "\(hub)/\(folder)/snapshots")
    }
}

/// The query owner has bounded startup/IPC waits. Indexing and reference workers retain their own budgets.
private final class WorkerDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var expired = false
    private var work: DispatchWorkItem?
    func arm(_ seconds: TimeInterval?, process: Process) {
        let token = lock.withLock {
            generation += 1
            expired = false
            work?.cancel()
            work = nil
            return generation
        }
        guard let seconds, seconds > 0 else { return }
        let timer = DispatchWorkItem { [weak self, weak process] in
            guard let self else { return }
            self.lock.withLock {
                guard self.generation == token, process?.isRunning == true else { return }
                self.expired = true
                if let process { Self.stop(process) }
            }
        }
        lock.withLock { work = timer }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer)
    }
    func finish() -> Bool {
        lock.withLock {
            generation += 1
            work?.cancel()
            work = nil
            let value = expired
            expired = false
            return value
        }
    }
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        #if os(Windows)
            process.terminate()  // Foundation uses the owned process handle / TerminateProcess on Windows.
        #else
            _ = kill(process.processIdentifier, SIGKILL)  // Only this model worker, never the Shell-launched application.
        #endif
    }
}
