import Foundation

public final class EmbeddingPool: ParallelEmbedding, InferenceReporting, @unchecked Sendable {
    private final class Slot {
        let model: any Embedder
        var busy = false
        init(_ model: any Embedder) { self.model=model }
    }
    private let changed = NSCondition()
    private let make: @Sendable () throws -> any Embedder
    private var slots: [Slot]
    private var creating = 0
    private var limit: Int
    private var stopped = false
    private var failure: String?
    private var capacityReason: String?
    public var onCapacity: (@Sendable (InferenceActivity)->Void)?
    private let batches = DispatchQueue(label: "DigUp.text-batches", qos: .utility)
    private var texts: [TextCall] = []
    private var batchesRunning = 0
    private let textQueues=(0..<3).map{DispatchQueue(label:"DigUp.text-inference-\($0)",qos:.utility)}
    private var availableTextQueues=Set(0..<3)
    private var flushScheduled = false
    public let info: WorkerInfo

    public init(maximum: Int, make: @escaping @Sendable () throws -> any Embedder) throws {
        self.make=make
        limit=min(3,max(1,maximum))
        let first=try make()
        info=first.info
        slots=[Slot(first)]
    }
    public var maximumParallelJobs: Int {
        changed.lock();defer{changed.unlock()};return limit
    }
    public var inferenceActivity: InferenceActivity? {
        changed.lock();defer{changed.unlock()}
        var activity=(slots.first?.model as? any InferenceReporting)?.inferenceActivity
        activity?.residentWorkers=slots.count
        activity?.effectiveLimit=GPUAdmission.configuredMaximum
        activity?.backgroundWorkers=limit
        activity?.reason=capacityReason
        return activity
    }
    private func checkout() throws -> Slot {
        changed.lock()
        while true {
            if stopped || failure != nil {
                let reason=failure ?? "Embedding pool is closed"
                changed.unlock();throw WorkerError.failed(reason)
            }
            if let slot=slots.first(where:{ !$0.busy }) {
                slot.busy=true;changed.unlock();return slot
            }
            if slots.count+creating<limit {
                creating+=1;changed.unlock()
                var creationPending=true
                do {
                    let model=try make()
                    guard model.info.vectorSource==info.vectorSource, model.info.backend==info.backend,
                        model.info.deviceId==info.deviceId, model.info.device==info.device else {
                        model.close();throw WorkerError.failed("Embedding workers resolved different devices or vector identities.")
                    }
                    changed.lock();creating-=1;creationPending=false
                    if stopped {changed.broadcast();changed.unlock();model.close();throw WorkerError.failed("Embedding pool is closed")}
                    let slot=Slot(model);slot.busy=true;slots.append(slot)
                    changed.broadcast();changed.unlock();return slot
                } catch {
                    changed.lock();if creationPending {creating=max(0,creating-1)}
                    if String(describing:error).contains("capacity_limited:") {
                        limit=max(1,slots.count+creating)
                        capacityReason=String(describing:error)
                        var activity=InferenceActivity(configuredLimit:GPUAdmission.configuredMaximum,effectiveLimit:GPUAdmission.configuredMaximum,
                            activeJobs:nil,phase:"limited",profile:"multimodal2048")
                        activity.residentWorkers=slots.count;activity.backgroundWorkers=limit;activity.reason=capacityReason
                        let callback=onCapacity
                        changed.broadcast();changed.unlock()
                        callback?(activity)
                        changed.lock();continue
                    }
                    failure=String(describing:error);changed.broadcast();changed.unlock();throw error
                }
            }
            changed.wait()
        }
    }
    private func using<T>(_ action:(any Embedder)throws->T)throws->T {
        let slot=try checkout()
        defer {
            changed.lock();slot.busy=false;changed.broadcast();changed.unlock()
        }
        return try action(slot.model)
    }
    public func embedTexts(_ inputs:[String])throws->[[Float]] {
        var output:[[Float]]=[]
        for start in stride(from:0,to:inputs.count,by:16) {
            let call=TextCall(Array(inputs[start..<min(inputs.count,start+16)]))
            batches.async { [self] in
                guard texts.count<128 else {
                    call.complete(.failure(WorkerError.failed("The bounded text queue is full")));return
                }
                texts.append(call)
                if !flushScheduled {
                    flushScheduled=true
                    batches.asyncAfter(deadline:.now()+0.002){[self] in flushScheduled=false;flush()}
                }
            }
            output += try call.wait()
        }
        return output
    }
    private func flush() {
        guard !texts.isEmpty,batchesRunning<maximumParallelJobs,let lane=availableTextQueues.min()else{return}
        availableTextQueues.remove(lane)
        var calls:[TextCall]=[]
        var inputs:[String]=[]
        var characters=0
        while let first=texts.first {
            let count=first.inputs.reduce(0){$0+$1.utf8.count}
            if !inputs.isEmpty && (inputs.count+first.inputs.count>16 || characters+count>8192){break}
            texts.removeFirst();calls.append(first);inputs+=first.inputs;characters+=count
        }
        batchesRunning+=1
        let work=TextBatch(calls:calls,inputs:inputs)
        textQueues[lane].async { [self] in
            do {
                let vectors=try using{try $0.embedTexts(work.inputs)}
                guard vectors.count==work.inputs.count else{throw WorkerError.failed("Text batch returned the wrong number of vectors")}
                var offset=0
                for call in work.calls {
                    call.complete(.success(Array(vectors[offset..<offset+call.inputs.count])))
                    offset+=call.inputs.count
                }
            } catch { for call in work.calls{call.complete(.failure(error))} }
            batches.async { [self] in batchesRunning-=1;availableTextQueues.insert(lane);flush() }
        }
        flush()
    }
    public func embedImages(_ paths:[String],budget:Int)throws->[Embedding] {
        guard !paths.isEmpty else{return []}
        return try using{try $0.embedImages(paths,budget:budget)}
    }
    public func embedAudio(_ paths:[String])throws->[Embedding] {
        guard !paths.isEmpty else{return []}
        return try using{try $0.embedAudio(paths)}
    }
    public func close() {
        changed.lock();stopped=true;changed.broadcast()
        while creating>0 || slots.contains(where:{$0.busy}){changed.wait()}
        let models=slots.map(\.model);slots=[]
        changed.unlock()
        for model in models{model.close()}
    }
    deinit{close()}
    private final class TextCall: @unchecked Sendable {
        let inputs:[String]
        private let ready=DispatchSemaphore(value:0)
        private var result:Result<[[Float]],any Error>?
        init(_ inputs:[String]){self.inputs=inputs}
        func complete(_ value:Result<[[Float]],any Error>){result=value;ready.signal()}
        func wait()throws->[[Float]]{ready.wait();return try result!.get()}
    }
    private struct TextBatch: Sendable { let calls:[TextCall];let inputs:[String] }
}
