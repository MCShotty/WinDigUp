import Foundation

public struct IndexPipelineSnapshot: Codable, Sendable {
    public var schemaVersion = 1
    public var preparationWorkers = 2
    public var inferenceWorkers = 0
    public var capacity = 2
    public var peakResidentJobs = 0
    public var preparedJobs = 0
    public var inferredJobs = 0
    public var committedJobs = 0
    public var preparationMs = 0.0
    public var inferenceMs = 0.0
    public var commitMs = 0.0
    public var modelLoadMs = 0.0
    public var ownerWaitMs = 0.0
    public var inferenceInputWaitMs = 0.0
    public var wallMs = 0.0
}

/// Credits are returned after commit, bounding prepared inputs and out-of-order results together.
final class IndexPipeline<Input: Sendable, Prepared: Sendable, Output: Sendable>: @unchecked Sendable {
    struct Item: Sendable {
        let index: Int
        let input: Input
        let value: Prepared
        let preparationMs: Double
    }
    struct Completion: Sendable {
        let item: Item
        let result: Result<Output, any Error>
        let inferenceMs: Double
    }

    private let inputs: [Input]
    private let prepare: @Sendable (Int, Input) -> Prepared
    private let cleanup: @Sendable (Prepared) -> Void
    private let condition = NSCondition()
    private let workers = DispatchGroup()
    private let began = ProcessInfo.processInfo.systemUptime
    private var admitted = 0
    private var dispatching = 0
    private var released = 0
    private var stopping = false
    private var closed = false
    private var startedInference = false
    private var prepared: [Int: Item] = [:]
    private var completed: [Int: Completion] = [:]
    private var measures = IndexPipelineSnapshot()

    init(_ inputs: [Input], preparationWorkers: Int = 2,
         prepare: @escaping @Sendable (Int, Input) -> Prepared,
         cleanup: @escaping @Sendable (Prepared) -> Void) {
        self.inputs = inputs
        self.prepare = prepare
        self.cleanup = cleanup
        measures.preparationWorkers = min(2, max(1, preparationWorkers))
        for lane in 0..<measures.preparationWorkers {
            workers.enter()
            DispatchQueue(label: "DigUp.prepare-\(lane)", qos: .utility).async { [self] in
                defer { workers.leave() }
                prepareLoop()
            }
        }
    }

    private func prepareLoop() {
        while true {
            condition.lock()
            while !stopping && admitted < inputs.count && admitted - released >= measures.capacity {
                condition.wait()
            }
            guard !stopping, admitted < inputs.count else { condition.unlock(); return }
            let index = admitted
            admitted += 1
            measures.peakResidentJobs = max(measures.peakResidentJobs, admitted - released)
            condition.unlock()

            let start = ProcessInfo.processInfo.systemUptime
            let value = prepare(index, inputs[index])
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            condition.lock()
            prepared[index] = Item(index: index, input: inputs[index], value: value, preparationMs: ms)
            measures.preparedJobs += 1
            measures.preparationMs += ms
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Before model startup, metadata-only jobs can commit without creating an encoder.
    func nextPrepared(shouldStop: () -> Bool) -> Item? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordOwnerWait(since: start) }
        while true {
            if shouldStop() { stop(); return nil }
            condition.lock()
            if let item = prepared[released] { condition.unlock(); return item }
            if stopping || released == inputs.count { condition.unlock(); return nil }
            _ = condition.wait(until: Date().addingTimeInterval(0.025))
            condition.unlock()
        }
    }

    func startInference(parallelism: Int, compute: @escaping @Sendable (Prepared) throws -> Output) {
        condition.lock()
        precondition(!startedInference)
        startedInference = true
        dispatching = released
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
            while !stopping && dispatching < inputs.count && prepared[dispatching] == nil {
                condition.wait()
            }
            measures.inferenceInputWaitMs += (ProcessInfo.processInfo.systemUptime - waiting) * 1000
            guard !stopping, dispatching < inputs.count, let item = prepared[dispatching] else {
                condition.unlock(); return
            }
            dispatching += 1
            condition.unlock()

            let start = ProcessInfo.processInfo.systemUptime
            let result = Result { try compute(item.value) }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            condition.lock()
            completed[item.index] = Completion(item: item, result: result, inferenceMs: ms)
            measures.inferredJobs += 1
            measures.inferenceMs += ms
            if case .failure = result { stopping = true }
            condition.broadcast()
            condition.unlock()
        }
    }

    func next(shouldStop: () -> Bool) -> Completion? {
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordOwnerWait(since: start) }
        while true {
            if shouldStop() { stop(); return nil }
            condition.lock()
            if let item = completed[released] { condition.unlock(); return item }
            if released == inputs.count || stopping && released >= dispatching {
                condition.unlock(); return nil
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.025))
            condition.unlock()
        }
    }

    func release(_ item: Item, commitMs: Double, committed: Bool = true) {
        cleanup(item.value)
        condition.lock()
        precondition(item.index == released)
        prepared.removeValue(forKey: item.index)
        completed.removeValue(forKey: item.index)
        released += 1
        if committed { measures.committedJobs += 1 }
        measures.commitMs += commitMs
        condition.broadcast()
        condition.unlock()
    }

    private func recordOwnerWait(since start: Double) {
        condition.lock()
        measures.ownerWaitMs += (ProcessInfo.processInfo.systemUptime - start) * 1000
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        condition.broadcast()
        condition.unlock()
    }

    /// The caller owns commits. Drain all file/model users before deleting scratch or closing the model.
    func close() {
        stop()
        workers.wait()
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        let abandoned = Array(prepared.values)
        prepared.removeAll()
        completed.removeAll()
        condition.unlock()
        for item in abandoned { cleanup(item.value) }
    }

    func snapshot(modelLoadMs: Double) -> IndexPipelineSnapshot {
        condition.lock()
        defer { condition.unlock() }
        var value = measures
        value.modelLoadMs = modelLoadMs
        value.wallMs = (ProcessInfo.processInfo.systemUptime - began) * 1000
        return value
    }
}
