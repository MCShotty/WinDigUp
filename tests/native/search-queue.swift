// Compile with Sources/digup/SearchWorkQueue.swift. Host scheduling test; no neural model or accelerator.
import Foundation

final class Counts: @unchecked Sendable {
    let lock = NSLock()
    var started = 0, cancelled = 0
    func start() { lock.withLock { started += 1 } }
    func cancel() { lock.withLock { cancelled += 1 } }
}
@main struct SearchQueueChecks {
    static func main() {
        let previews = SearchWorkQueue(concurrency: 2, capacity: 32)
        let blocked = DispatchSemaphore(value: 0)
        let began = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let counts = Counts()
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<36 {
            previews.submit(key: "preview-\(index)", cancel: { counts.cancel() }) {
                counts.start()
                began.signal()
                blocked.wait()
                finished.signal()
            }
        }
        precondition(ProcessInfo.processInfo.systemUptime - start < 0.25, "Admission waited for preview capacity")
        precondition(began.wait(timeout: .now() + 2) == .success)
        precondition(began.wait(timeout: .now() + 2) == .success)
        precondition(counts.lock.withLock { counts.started } == 2)
        let lexical = SearchWorkQueue()
        let keyword = DispatchSemaphore(value: 0)
        lexical.submit(key: "keyword") { keyword.signal() }
        precondition(keyword.wait(timeout: .now() + 0.25) == .success, "Keyword work waited for previews")
        previews.stop()
        blocked.signal()
        blocked.signal()
        precondition(finished.wait(timeout: .now() + 2) == .success)
        precondition(finished.wait(timeout: .now() + 2) == .success)
        precondition(counts.lock.withLock { counts.cancelled } == 34)
        let encoder = SearchWorkQueue()
        let gate = DispatchSemaphore(value: 0)
        let running = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let encoded = Counts()
        encoder.submit(key: "typing") {
            encoded.start()
            running.signal()
            gate.wait()
            done.signal()
        }
        precondition(running.wait(timeout: .now() + 2) == .success)
        for _ in 0..<12 {
            encoder.submit(key: "typing", cancel: { encoded.cancel() }) {
                encoded.start()
                done.signal()
            }
        }
        gate.signal()
        precondition(done.wait(timeout: .now() + 2) == .success)
        precondition(done.wait(timeout: .now() + 2) == .success)
        precondition(encoded.lock.withLock { encoded.started } == 2)
        precondition(encoded.lock.withLock { encoded.cancelled } == 11)
        print(
            "PASS: two active previews, bounded nonblocking admission, independent keywords, explicit cancellation and one newest pending embedding"
        )
    }
}
