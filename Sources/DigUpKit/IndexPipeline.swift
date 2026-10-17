import Foundation

public struct IndexPipelineSourceSnapshot: Codable, Sendable {
    public var preparedJobs = 0
    public var inferredJobs = 0
    public var committedJobs = 0
    public var preparationMs = 0.0
    public var inferenceMs = 0.0
    public var commitMs = 0.0
}

public struct IndexPipelineSnapshot: Codable, Sendable {
    public var schemaVersion = 2
    public var epoch = UUID().uuidString
    public var capturedAt = 0.0
    public var scope = "shared"
    public var source: String?
    public var sources: [String: IndexPipelineSourceSnapshot] = [:]
    public var preparationWorkers = 2
    public var inferenceWorkers = 0
    public var capacity = 2
    public var peakResidentJobs = 0
    public var admittedJobs = 0
    public var preparingJobs = 0
    public var readyJobs = 0
    public var runningJobs = 0
    public var completedJobs = 0
    public var preparedJobs = 0
    public var inferredJobs = 0
    public var committedJobs = 0
    public var preparationMs = 0.0
    public var inferenceMs = 0.0
    public var commitMs = 0.0
    public var cleanupMs = 0.0
    public var notificationMs = 0.0
    public var modelLoadMs = 0.0
    public var ownerWaitMs = 0.0
    public var inferenceInputWaitMs = 0.0
    public var queueBuildMs = 0.0
    public var queueFetchMs = 0.0
    public var queuePages = 0
    public var queueRows = 0
    public var peakBufferedRecords = 0
    public var retainedPreparedBytes = 0
    public var peakPreparedBytes = 0
    public var scratchBytes = 0
    public var peakScratchBytes = 0
    public var blockedBy = "waiting_for_input"
    public var wallMs = 0.0
}

/// Credits include preparation, active inference and unpublished results.
final class IndexPipeline<Input: Sendable, Prepared: Sendable, Output: Sendable>: @unchecked Sendable {
    struct Item: Sendable {
        let index: Int
        let input: Input
        let value: Prepared
        let preparationMs: Double
        let retainedBytes: Int
        let scratchBytes: Int
    }
    struct Completion: Sendable {
        let item: Item
        let result: Result<Output, any Error>
        let inferenceMs: Double
    }

    private let fixedInputs: [Input]?
    private let nextInput: (() throws -> Input?)?
    private let prepare: @Sendable (Int, Input) -> Prepared
    private let cleanup: @Sendable (Prepared) -> Void
    private let source: @Sendable (Input) -> String
    private let sizes: @Sendable (Prepared) -> (memory: Int, scratch: Int)
    private let condition = NSCondition()
    private let workers = DispatchGroup()
    private let began = ProcessInfo.processInfo.systemUptime
    private var admitted = 0
    private var released = 0
    private var stopping = false
    private var closed = false
    private var sourceEnded = false
    private var startedInference = false
    private var failure: (any Error)?
    private var queued: [Int: Input] = [:]
    private var preparing: Set<Int> = []
    private var ready: Set<Int> = []
    private var running: Set<Int> = []
    private var prepared: [Int: Item] = [:]
    private var completed: [Int: Completion] = [:]
    private var measures = IndexPipelineSnapshot()

    init(_ inputs: [Input], preparationWorkers: Int = 2,
         prepare: @escaping @Sendable (Int, Input) -> Prepared,
         cleanup: @escaping @Sendable (Prepared) -> Void) {
        fixedInputs = inputs
        nextInput = nil
        self.prepare = prepare
        self.cleanup = cleanup
        source = { _ in "0" }
        sizes = { _ in (0, 0) }
        startPreparation(preparationWorkers)
    }

    /// Only next/nextPrepared call the source, on the database owner's thread.
    init(nextInput: @escaping () throws -> Input?, preparationWorkers: Int = 2,
         source: @escaping @Sendable (Input) -> String,
         sizes: @escaping @Sendable (Prepared) -> (memory: Int, scratch: Int),
         prepare: @escaping @Sendable (Int, Input) -> Prepared,
         cleanup: @escaping @Sendable (Prepared) -> Void) {
        fixedInputs = nil
        self.nextInput = nextInput
        self.source = source
        self.sizes = sizes
        self.prepare = prepare
        self.cleanup = cleanup
        startPreparation(preparationWorkers)
    }

    private func startPreparation(_ count: Int) {
        measures.preparationWorkers = min(2, max(1, count))
        for lane in 0..<measures.preparationWorkers {
            workers.enter()
            DispatchQueue(label: "DigUp.prepare-\(lane)", qos: .utility).async { [self] in
                defer { workers.leave() }
                prepareLoop()
            }
        }
    }

    private func refill() {
        guard let nextInput else { return }
        while true {
            condition.lock()
            let canAdmit = !stopping && !sourceEnded && admitted - released < measures.capacity
            condition.unlock()
            guard canAdmit else { return }
            do {
                let input = try nextInput()
                condition.lock()
                guard !stopping else { condition.unlock(); return }
                guard let input else {
                    sourceEnded = true
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                queued[admitted] = input
                admitted += 1
                measures.peakResidentJobs = max(measures.peakResidentJobs, admitted - released)
                condition.broadcast()
                condition.unlock()
            } catch {
                condition.lock()
                failure = failure ?? error
                stopping = true
                condition.broadcast()
                condition.unlock()
                return
            }
        }
    }

    private func prepareLoop() {
        while true {
            condition.lock()
            var selected: (Int, Input)?
            while !stopping && selected == nil {
                if let fixedInputs {
                    if admitted == fixedInputs.count {
                        sourceEnded = true
                        condition.broadcast()
                        condition.unlock()
                        return
                    }
                    if admitted - released < measures.capacity {
                        selected = (admitted, fixedInputs[admitted])
                        admitted += 1
                        measures.peakResidentJobs = max(measures.peakResidentJobs, admitted - released)
                    }
                } else if let index = queued.keys.min(), let input = queued.removeValue(forKey: index) {
                    selected = (index, input)
                } else if sourceEnded {
                    condition.unlock()
                    return
                }
                if selected == nil { condition.wait() }
            }
            guard !stopping, let (index, input) = selected else { condition.unlock(); return }
            preparing.insert(index)
            condition.unlock()

            let start = ProcessInfo.processInfo.systemUptime
            let value = prepare(index, input)
            let footprint = sizes(value)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            condition.lock()
            preparing.remove(index)
            prepared[index] = Item(index: index, input: input, value: value, preparationMs: ms,
                                   retainedBytes: footprint.memory, scratchBytes: footprint.scratch)
            ready.insert(index)
            measures.preparedJobs += 1
            measures.preparationMs += ms
            measures.retainedPreparedBytes += footprint.memory
            measures.scratchBytes += footprint.scratch
            measures.peakPreparedBytes = max(measures.peakPreparedBytes, measures.retainedPreparedBytes)
            measures.peakScratchBytes = max(measures.peakScratchBytes, measures.scratchBytes)
            let key = source(input)
            measures.sources[key, default: IndexPipelineSourceSnapshot()].preparedJobs += 1
            measures.sources[key, default: IndexPipelineSourceSnapshot()].preparationMs += ms
            condition.broadcast()
            condition.unlock()
        }
    }

    func nextPrepared(shouldStop: () -> Bool, canStartWith: (Prepared) -> Bool = { _ in false },
                      onTick: () -> Void = {}) -> Item? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordOwnerWait(since: start) }
        while true {
            if shouldStop() { stop(); return nil }
            refill()
            onTick()
            condition.lock()
            if let item = prepared[released] { condition.unlock(); return item }
            if let item = ready.sorted().compactMap({ prepared[$0] }).first(where: { canStartWith($0.value) }) {
                condition.unlock()
                return item
            }
            if stopping || sourceEnded && released == admitted { condition.unlock(); return nil }
            _ = condition.wait(until: Date().addingTimeInterval(0.025))
            condition.unlock()
        }
    }

    func startInference(parallelism: Int, compute: @escaping @Sendable (Prepared) throws -> Output) {
        condition.lock()
        precondition(!startedInference)
        startedInference = true
        let width = min(3, max(1, parallelism))
        measures.inferenceWorkers = width
        measures.capacity = width == 1 ? 2 : width * 2 + 2
        condition.broadcast()
        condition.unlock()
        for lane in 0..<width {
            workers.enter()
            DispatchQueue(label: "DigUp.index-infer-\(lane)", qos: .utility).async { [self] in
                defer { workers.leave() }
                inferenceLoop(compute)
            }
        }
    }

    private func inferenceLoop(_ compute: @Sendable (Prepared) throws -> Output) {
        while true {
            let waiting = ProcessInfo.processInfo.systemUptime
            condition.lock()
            while !stopping && ready.isEmpty && !(sourceEnded && preparing.isEmpty && queued.isEmpty) {
                condition.wait()
            }
            measures.inferenceInputWaitMs += (ProcessInfo.processInfo.systemUptime - waiting) * 1000
            guard !stopping, let index = ready.min(), let item = prepared[index] else {
                condition.unlock()
                return
            }
            ready.remove(index)
            running.insert(index)
            condition.unlock()

            let start = ProcessInfo.processInfo.systemUptime
            let result = Result { try compute(item.value) }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            condition.lock()
            running.remove(index)
            completed[index] = Completion(item: item, result: result, inferenceMs: ms)
            measures.inferredJobs += 1
            measures.inferenceMs += ms
            let key = source(item.input)
            measures.sources[key, default: IndexPipelineSourceSnapshot()].inferredJobs += 1
            measures.sources[key, default: IndexPipelineSourceSnapshot()].inferenceMs += ms
            if case .failure(let error) = result {
                failure = failure ?? error
                stopping = true
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    func next(shouldStop: () -> Bool, onTick: () -> Void = {}) -> Completion? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordOwnerWait(since: start) }
        while true {
            if shouldStop() { stop(); return nil }
            refill()
            onTick()
            condition.lock()
            if let item = completed[released] { condition.unlock(); return item }
            // Failure can leave an earlier input prepared but never dispatched.
            if sourceEnded && released == admitted || stopping && !running.contains(released) {
                condition.unlock()
                return nil
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.025))
            condition.unlock()
        }
    }

    func throwIfFailed() throws {
        condition.lock()
        let error = failure
        condition.unlock()
        if let error { throw error }
    }

    func release(_ item: Item, commitMs: Double, committed: Bool = true) {
        let start = ProcessInfo.processInfo.systemUptime
        cleanup(item.value)
        let cleanupMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        condition.lock()
        precondition(item.index == released)
        prepared.removeValue(forKey: item.index)
        ready.remove(item.index)
        completed.removeValue(forKey: item.index)
        released += 1
        if committed {
            measures.committedJobs += 1
            measures.sources[source(item.input), default: IndexPipelineSourceSnapshot()].committedJobs += 1
        }
        measures.commitMs += commitMs
        measures.sources[source(item.input), default: IndexPipelineSourceSnapshot()].commitMs += commitMs
        measures.cleanupMs += cleanupMs
        measures.retainedPreparedBytes -= item.retainedBytes
        measures.scratchBytes -= item.scratchBytes
        condition.broadcast()
        condition.unlock()
    }

    private func recordOwnerWait(since start: Double) {
        condition.lock()
        measures.ownerWaitMs += (ProcessInfo.processInfo.systemUptime - start) * 1000
        condition.unlock()
    }

    func fail(_ error: any Error) {
        condition.lock()
        failure = failure ?? error
        stopping = true
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()
    }

    /// Scratch and models outlive every submitted operation.
    func close() {
        stop()
        workers.wait()
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        let abandoned = Array(prepared.values)
        prepared.removeAll()
        queued.removeAll()
        ready.removeAll()
        completed.removeAll()
        measures.retainedPreparedBytes = 0
        measures.scratchBytes = 0
        condition.unlock()
        for item in abandoned { cleanup(item.value) }
    }

    func snapshot(modelLoadMs: Double) -> IndexPipelineSnapshot {
        condition.lock()
        defer { condition.unlock() }
        var value = measures
        value.capturedAt = Date().timeIntervalSince1970
        value.admittedJobs = admitted
        value.preparingJobs = preparing.count
        value.readyJobs = ready.count
        value.runningJobs = running.count
        value.completedJobs = completed.count
        value.modelLoadMs = modelLoadMs
        value.wallMs = (ProcessInfo.processInfo.systemUptime - began) * 1000
        if failure != nil { value.blockedBy = "failed" }
        else if stopping && released != admitted { value.blockedBy = "cancelled" }
        else if sourceEnded && released == admitted { value.blockedBy = "idle" }
        else if admitted - released == measures.capacity && !completed.isEmpty { value.blockedBy = "publication_backpressure" }
        else if !running.isEmpty { value.blockedBy = "running" }
        else if !preparing.isEmpty { value.blockedBy = "preparing" }
        else { value.blockedBy = "waiting_for_input" }
        return value
    }
}
