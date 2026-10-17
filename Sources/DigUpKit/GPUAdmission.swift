import CGPUAdmission
import Foundation

public struct InferenceActivity: Codable, Sendable {
    public var schemaVersion = 1
    public var configuredLimit: Int
    public var effectiveLimit: Int
    public var activeJobs: Int?
    public var residentWorkers: Int?
    public var phase: String
    public var profile: String
    public var queueMs: Double = 0
    public var executionMs: Double = 0
    public var inputs: Int = 0
    public var reason: String?
    public var workerID: Int32 = ProcessInfo.processInfo.processIdentifier
}
public protocol InferenceReporting: AnyObject {
    var inferenceActivity: InferenceActivity? { get }
}
public protocol ParallelEmbedding: Embedder {
    var maximumParallelJobs: Int { get }
}
public final class GPULease: @unchecked Sendable {
    private var raw: OpaquePointer?
    fileprivate init(_ raw: OpaquePointer) { self.raw = raw }
    public func release() {
        if let raw { digup_lease_release(raw); self.raw = nil }
    }
    deinit { release() }
}

/// OS-owned locks release admission after a killed process; their files contain no document data.
public final class GPUAdmission: @unchecked Sendable {
    public let directory: URL
    public let maximum: Int
    private let lock = NSLock()
    private var last: InferenceActivity?
    public var onActivity: (@Sendable (InferenceActivity) -> Void)?
    public var activity: InferenceActivity? { lock.withLock { last } }
    public static var configuredMaximum: Int {
        let raw = ProcessInfo.processInfo.environment["DIGUP_GPU_JOBS"] ?? "0"
        guard let number = Int(raw), (0...3).contains(number) else { return 1 }
        return number == 0 ? 3 : number
    }
    public init(identity: String, maximum: Int = GPUAdmission.configuredMaximum, root: URL? = nil) throws {
        self.maximum = min(3, max(1, maximum))
        let folder = root ?? AppPaths.defaultIndex.deletingLastPathComponent().appendingPathComponent("inference")
        var hash: UInt64 = 14695981039346656037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        directory = folder.appendingPathComponent("gpu-" + String(hash, radix: 16))
        #if os(Windows)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        #else
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        #endif
        let probe = directory.appendingPathComponent("permission-test")
        guard let lease = Self.tryLease(probe) else {
            throw WorkerError.failed("GPU admission storage is unavailable. Check permissions and retry.")
        }
        lease.release()
    }
    private static func tryLease(_ file: URL, shared: Bool = false) -> GPULease? {
        guard let raw = file.path.withCString({ digup_lease_try($0, shared ? 1 : 0) }) else { return nil }
        return GPULease(raw)
    }

    public func request(profile: String, foreground: Bool, timeout: Double = 180,
                        cancelled: () -> Bool = { false }) throws -> Operation {
        let began = digup_monotonic_seconds()
        var foregroundLease: GPULease?
        let waiting = InferenceActivity(configuredLimit: maximum, effectiveLimit: maximum,
            activeJobs: nil, phase: "waiting", profile: profile)
        lock.withLock { last = waiting }; onActivity?(waiting)
        while digup_monotonic_seconds() - began < timeout {
            if cancelled() { throw WorkerError.failed("Inference request cancelled") }
            guard let admission = Self.tryLease(directory.appendingPathComponent("admission")) else {
                Thread.sleep(forTimeInterval: 0.005); continue
            }
            if foreground && foregroundLease == nil {
                foregroundLease = Self.tryLease(directory.appendingPathComponent("foreground"), shared: true)
            }
            let priorityProbe = foreground ? nil : Self.tryLease(directory.appendingPathComponent("foreground"))
            let lastForeground = (try? String(contentsOf: directory.appendingPathComponent("last-foreground"), encoding: .utf8)).flatMap(Double.init) ?? 0
            let delta = digup_monotonic_seconds() - lastForeground
            let quiet = delta < 0 || delta >= 1
            if foreground || priorityProbe != nil && quiet {
                var held: [GPULease] = []
                var occupied = 0
                for slot in 0..<3 {
                    if let lease = Self.tryLease(directory.appendingPathComponent("slot-\(slot)")) { held.append(lease) }
                    else { occupied += 1 }
                }
                if occupied < maximum, let slot = held.popLast() {
                    held.forEach { $0.release() }; priorityProbe?.release()
                    admission.release()
                    let state = InferenceActivity(configuredLimit: maximum, effectiveLimit: maximum,
                        activeJobs: occupied + 1, phase: "running", profile: profile,
                        queueMs: (digup_monotonic_seconds()-began)*1000)
                    lock.withLock { last = state }; onActivity?(state)
                    return Operation(owner: self, slot: slot, foreground: foregroundLease, state: state)
                }
                held.forEach { $0.release() }
            }
            priorityProbe?.release()
            admission.release()
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw WorkerError.failed("Timed out waiting for the selected GPU. Check Activity and retry explicitly.")
    }
    public func resident() throws -> (GPULease, Int) {
        var available: [GPULease] = []
        for slot in 0..<4 {
            if let lease = Self.tryLease(directory.appendingPathComponent("resident-\(slot)")) { available.append(lease) }
        }
        let others = 4-available.count
        guard let lease = available.popLast() else {
            throw WorkerError.failed("capacity_limited: Four model workers are already resident on this GPU.")
        }
        available.forEach { $0.release() }
        return (lease, others)
    }
    private func countActive() -> Int? {
        guard let admission = Self.tryLease(directory.appendingPathComponent("admission")) else { return nil }
        defer { admission.release() }
        var count = 0
        for slot in 0..<3 {
            if let lease = Self.tryLease(directory.appendingPathComponent("slot-\(slot)")) { lease.release() }
            else { count += 1 }
        }
        return count
    }
    public func loading(cancelled: () -> Bool = { false }) throws -> GPULease {
        let began = digup_monotonic_seconds()
        while digup_monotonic_seconds()-began < 180 {
            if cancelled() { throw WorkerError.failed("Model loading cancelled") }
            if let lease = Self.tryLease(directory.appendingPathComponent("loading")) { return lease }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw WorkerError.failed("Another model is still loading on this GPU. Retry explicitly.")
    }
    public final class Operation {
        private let owner: GPUAdmission
        private let slot: GPULease
        private let foreground: GPULease?
        private let started = digup_monotonic_seconds()
        private var state: InferenceActivity
        private var finished = false
        fileprivate init(owner: GPUAdmission, slot: GPULease, foreground: GPULease?, state: InferenceActivity) {
            self.owner=owner; self.slot=slot; self.foreground=foreground; self.state=state
        }
        public func finish(inputs: Int = 0) {
            guard !finished else { return }
            finished=true
            state.executionMs=(digup_monotonic_seconds()-started)*1000
            state.inputs=inputs
            state.phase="idle"
            state.activeJobs=nil
            if foreground != nil {
                try? String(digup_monotonic_seconds()).write(to: owner.directory.appendingPathComponent("last-foreground"), atomically:true, encoding:.utf8)
            }
            foreground?.release();slot.release()
            state.activeJobs=owner.countActive()
            owner.lock.withLock { owner.last=state }; owner.onActivity?(state)
        }
        deinit { finish() }
    }
}
