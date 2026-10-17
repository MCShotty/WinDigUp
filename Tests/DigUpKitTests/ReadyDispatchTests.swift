import Foundation
import Testing
@testable import DigUpKit

struct ReadyDispatchTests {
    @Test func laterPreparedInputCanUseAnAvailableInferenceLane() throws {
        let events = IndexPipelineTests.Events()
        let releaseFirst = DispatchSemaphore(value: 0)
        let pipeline = IndexPipeline<Int, Int, Int>(Array(0..<12), prepare: { _, value in
            if value == 0 { _ = releaseFirst.wait(timeout: .now() + 10) }
            events.mark(value, preparation: true)
            return value
        }, cleanup: { events.clean($0) })
        defer { releaseFirst.signal(); pipeline.close() }
        pipeline.startInference(parallelism: 3) { value in
            events.mark(value)
            return value
        }
        let readyRan = events.wait(for: [1])
        let baseline = ProcessInfo.processInfo.environment["DIGUP_INDEX_BASELINE"] == "1"
        #expect(readyRan == !baseline)
        releaseFirst.signal()
        var received: [Int] = []
        while let completion = pipeline.next(shouldStop: { false }) {
            received.append(try completion.result.get())
            pipeline.release(completion.item, commitMs: 0)
        }
        #expect(received == Array(0..<12))
        print("READY_DISPATCH_EVIDENCE: baseline=\(baseline) laterReadyInputRan=\(readyRan)")
    }
}
