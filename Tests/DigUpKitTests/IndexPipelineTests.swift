import Foundation
import Testing
@testable import DigUpKit

struct IndexPipelineTests {
    final class Events: @unchecked Sendable {
        let condition = NSCondition()
        var prepared: Set<Int> = []
        var computed: Set<Int> = []
        var cleaned: [Int] = []
        func mark(_ index: Int, preparation: Bool = false) {
            condition.lock()
            if preparation { prepared.insert(index) } else { computed.insert(index) }
            condition.broadcast()
            condition.unlock()
        }
        func clean(_ index: Int) {
            condition.lock(); cleaned.append(index); condition.broadcast(); condition.unlock()
        }
        func wait(for expected: Set<Int>, preparation: Bool = false) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while !expected.isSubset(of: preparation ? prepared : computed) {
                if !condition.wait(until: deadline) { return false }
            }
            return true
        }
    }

    @Test func slowOldestInferenceDoesNotBlockAvailableLanes() throws {
        let events = Events()
        let releaseFirst = DispatchSemaphore(value: 0)
        let pipeline = IndexPipeline<Int, Int, Int>(Array(0..<12), prepare: { _, value in
            events.mark(value, preparation: true)
            return value
        }, cleanup: { events.clean($0) })
        defer { releaseFirst.signal(); pipeline.close() }
        pipeline.startInference(parallelism: 3) { value in
            if value == 0 {
                guard releaseFirst.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            }
            events.mark(value)
            return value * 2
        }
        #expect(events.wait(for: Set(1..<8)))
        let blocked = pipeline.snapshot(modelLoadMs: 0)
        #expect(blocked.peakResidentJobs == 8)
        #expect(blocked.preparedJobs == 8)
        releaseFirst.signal()
        var received: [Int] = []
        while let result = pipeline.next(shouldStop: { false }) {
            received.append(try result.result.get())
            pipeline.release(result.item, commitMs: 1)
        }
        pipeline.close()
        #expect(received == (0..<12).map { $0 * 2 })
        #expect(events.cleaned.sorted() == Array(0..<12))
        #expect(pipeline.snapshot(modelLoadMs: 0).committedJobs == 12)
    }

    @Test func slowWriterDoesNotStopFeedingInferenceAndCreditsBoundMemory() throws {
        let events = Events()
        let pipeline = IndexPipeline<Int, Int, Int>(Array(0..<20), prepare: { _, value in
            events.mark(value, preparation: true); return value
        }, cleanup: { events.clean($0) })
        defer { pipeline.close() }
        pipeline.startInference(parallelism: 3) { value in events.mark(value); return value }
        let first = try #require(pipeline.next(shouldStop: { false }))
        #expect(first.item.index == 0)
        #expect(events.wait(for: Set(0..<8)))
        #expect(pipeline.snapshot(modelLoadMs: 0).preparedJobs == 8)
        pipeline.release(first.item, commitMs: 10)
        var count = 1
        while let value = pipeline.next(shouldStop: { false }) {
            #expect(try value.result.get() == count)
            pipeline.release(value.item, commitMs: 1)
            count += 1
        }
        #expect(count == 20)
        let stats = pipeline.snapshot(modelLoadMs: 12)
        #expect(stats.peakResidentJobs == 8)
        #expect(stats.modelLoadMs == 12)
        #expect(stats.commitMs == 29)
        #expect(stats.inferenceWorkers == 3)
    }

    @Test func preparationOverlapsAndStopDrainsScratchExactlyOnce() throws {
        let events = Events()
        let releaseFirst = DispatchSemaphore(value: 0)
        let pipeline = IndexPipeline<Int, Int, Int>(Array(0..<20), prepare: { _, value in
            events.mark(value, preparation: true)
            if value == 0 { _ = releaseFirst.wait(timeout: .now() + 5) }
            return value
        }, cleanup: { events.clean($0) })
        #expect(events.wait(for: [0, 1], preparation: true))
        #expect(pipeline.nextPrepared(shouldStop: { true }) == nil)
        releaseFirst.signal()
        pipeline.close()
        pipeline.close()
        #expect(events.cleaned.sorted() == [0, 1])
        #expect(pipeline.snapshot(modelLoadMs: 0).inferredJobs == 0)
    }

    @Test func inferenceFailureKeepsEarlierResultsAndStopsNewAdmissions() throws {
        let failed = DispatchSemaphore(value: 0)
        let events = Events()
        let pipeline = IndexPipeline<Int, Int, Int>(Array(0..<40), prepare: { _, value in
            events.mark(value, preparation: true); return value
        }, cleanup: { events.clean($0) })
        defer { pipeline.close() }
        pipeline.startInference(parallelism: 3) { value in
            if value == 0 {
                guard failed.wait(timeout: .now() + 5) == .success else { throw TestFailure.timeout }
            }
            if value == 1 { failed.signal(); throw TestFailure.inference }
            return value
        }
        let first = try #require(pipeline.next(shouldStop: { false }))
        #expect(try first.result.get() == 0)
        pipeline.release(first.item, commitMs: 0)
        let second = try #require(pipeline.next(shouldStop: { false }))
        #expect(throws: TestFailure.inference) { try second.result.get() }
        pipeline.close()
        #expect(events.cleaned.count == events.prepared.count)
        #expect(Set(events.cleaned) == events.prepared)
        #expect(pipeline.snapshot(modelLoadMs: 0).preparedJobs <= 9)
        #expect(pipeline.snapshot(modelLoadMs: 0).committedJobs == 1)
    }

    @Test func pauseDiscardsUncommittedResultsWithoutAdvancingTheCursor() throws {
        let events = Events()
        let pipeline = IndexPipeline<Int, Int, Int>(Array(0..<10), prepare: { _, value in
            events.mark(value, preparation: true); return value
        }, cleanup: { events.clean($0) })
        pipeline.startInference(parallelism: 1) { value in events.mark(value); return value }
        let first = try #require(pipeline.next(shouldStop: { false }))
        pipeline.release(first.item, commitMs: 0)
        #expect(pipeline.next(shouldStop: { true }) == nil)
        pipeline.close()
        let stats = pipeline.snapshot(modelLoadMs: 0)
        #expect(stats.committedJobs == 1)
        #expect(stats.peakResidentJobs <= 2)
        #expect(events.cleaned.count == events.prepared.count)
    }

    @Test func metadataOnlyPreparationDoesNotNeedAnInferenceOwner() throws {
        let pipeline = IndexPipeline<Int, Int, Int>([0, 1, 2], prepare: { _, value in value }, cleanup: { _ in })
        defer { pipeline.close() }
        var seen: [Int] = []
        while let item = pipeline.nextPrepared(shouldStop: { false }) {
            seen.append(item.value)
            pipeline.release(item, commitMs: 0)
        }
        #expect(seen == [0, 1, 2])
        #expect(pipeline.snapshot(modelLoadMs: 0).inferenceWorkers == 0)
    }

    @Test func watchdogRetainsTheOtherReaderWhenOneFinishes() {
        let first = UUID().uuidString, second = UUID().uuidString
        Indexer.startReading(first, token: first)
        Indexer.startReading(second, token: second)
        defer { Indexer.endReading(token: first); Indexer.endReading(token: second) }
        Indexer.endReading(token: second)
        // Other suites can extract concurrently; this reader must remain tracked.
        #expect(Indexer.activeReadPaths.contains(first))
        #expect(!Indexer.activeReadPaths.contains(second))
    }

    enum TestFailure: Error, Equatable { case timeout, inference }
}
