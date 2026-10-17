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

    @Test func aFailureBeyondAnUndispatchedGapIsReportedWithoutWaitingForTheGap() throws {
        enum Failure: Error, Equatable { case fixture }
        let firstPreparing = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let failureSubmitted = DispatchSemaphore(value: 0)
        let pipeline = IndexPipeline<Int, Int, Int>(Array(0..<12), prepare: { _, value in
            if value == 0 { firstPreparing.signal(); _ = releaseFirst.wait(timeout: .now() + 10) }
            return value
        }, cleanup: { _ in })
        defer { releaseFirst.signal(); pipeline.close() }
        #expect(firstPreparing.wait(timeout: .now() + 5) == .success)
        pipeline.startInference(parallelism: 3) { value in
            if value == 1 { failureSubmitted.signal(); throw Failure.fixture }
            return value
        }
        #expect(failureSubmitted.wait(timeout: .now() + 5) == .success)
        #expect(pipeline.next(shouldStop: { false }) == nil)
        #expect(throws: Failure.fixture) { try pipeline.throwIfFailed() }
        releaseFirst.signal()
    }

    @Test func streamingSourceRunsOnlyOnItsOwnerAndRemainsBounded() throws {
        let owner = Thread.current
        var nextInput = 0
        let pipeline = IndexPipeline<Int, Int, Int>(nextInput: {
            #expect(Thread.current === owner)
            guard nextInput < 513 else { return nil }
            defer { nextInput += 1 }
            return nextInput
        }, source: { _ in "0" }, sizes: { _ in (16, 0) }, prepare: { _, value in value },
        cleanup: { _ in })
        defer { pipeline.close() }
        let first = try #require(pipeline.nextPrepared(shouldStop: { false }))
        #expect(first.index == 0)
        pipeline.startInference(parallelism: 3) { $0 }
        var results: [Int] = []
        while let completion = pipeline.next(shouldStop: { false }) {
            results.append(try completion.result.get())
            pipeline.release(completion.item, commitMs: 0)
        }
        try pipeline.throwIfFailed()
        #expect(results == Array(0..<513))
        let snapshot = pipeline.snapshot(modelLoadMs: 0)
        #expect(snapshot.peakResidentJobs <= 8)
        #expect(snapshot.peakPreparedBytes <= 8 * 16)
        #expect(snapshot.retainedPreparedBytes == 0)
        #expect(snapshot.blockedBy == "idle")
    }

    @Test func queueFailureStopsAdmissionsAndPreservesItsOriginalError() throws {
        enum Failure: Error, Equatable { case database }
        var number = 0
        let pipeline = IndexPipeline<Int, Int, Int>(nextInput: {
            defer { number += 1 }
            if number == 5 { throw Failure.database }
            return number
        }, source: { _ in "0" }, sizes: { _ in (0, 0) }, prepare: { _, value in value }, cleanup: { _ in })
        defer { pipeline.close() }
        _ = pipeline.nextPrepared(shouldStop: { false })
        pipeline.startInference(parallelism: 3) { $0 }
        while let completion = pipeline.next(shouldStop: { false }) {
            _ = try completion.result.get()
            pipeline.release(completion.item, commitMs: 0)
        }
        #expect(throws: Failure.database) { try pipeline.throwIfFailed() }
        #expect(number == 6)
    }

}
