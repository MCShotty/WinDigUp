import Foundation
import Testing
import DigUpKit
@testable import digup

@Suite(.serialized)
struct ServiceSchedulingTests {
    enum FixtureError: Error { case drainedBeforeRefill }
    final class Model: ParallelEmbedding, @unchecked Sendable {
        let maximumParallelJobs = 3
        let info = WorkerInfo(model: "service-fixture", revision: "fixture", runtime: "fixture", dtype: "fixture",
                              dim: 768, textOnly: false, loadSeconds: nil)
        let condition = NSCondition()
        var calls = 0
        var fourthBeforeFirstFinished = false
        var inputs = 0
        func vectors(_ count: Int) throws -> [[Float]] {
            condition.lock()
            calls += 1
            inputs += count
            let ordinal = calls
            if ordinal == 4 { fourthBeforeFirstFinished = true; condition.broadcast() }
            if ordinal == 1 {
                let deadline = Date().addingTimeInterval(5)
                while !fourthBeforeFirstFinished {
                    if !condition.wait(until: deadline) {
                        condition.unlock()
                        throw FixtureError.drainedBeforeRefill
                    }
                }
            }
            condition.unlock()
            return (0..<count).map { _ in [Float(1)] + [Float](repeating: 0, count: 767) }
        }
        func embedTexts(_ texts: [String]) throws -> [[Float]] { try vectors(texts.count) }
        func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
            try vectors(paths.count).map { Embedding(vector: $0, error: nil) }
        }
        func embedAudio(_ paths: [String]) throws -> [Embedding] {
            try vectors(paths.count).map { Embedding(vector: $0, error: nil) }
        }
        func close() {}
    }

    @Test func imageServiceRefillsBeforeTwentyFourFilesDrain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("digup-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("pictures")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let picture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DigUpKitTests/Pictures/pattern-o6.jpg")
        for index in 0..<96 {
            try FileManager.default.copyItem(at: picture, to: documents.appendingPathComponent("picture-\(index).jpg"))
        }
        let directory = root.appendingPathComponent("index")
        let store = try IndexStore(directory: directory)
        let fake = Model()
        let shared = SharedEmbedder { fake }
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { try shared.embedder() })
        let service = IndexService(main: .init(store: store, indexer: indexer, roots: [documents], keepOnly: nil),
            code: nil, folder: directory, model: shared, modelReady: { true },
            backfill: true, newFilesLimit: 50, linger: 0, output: { _ in })
        _ = service.serve(commandInput: false)
        let baseline = ProcessInfo.processInfo.environment["DIGUP_INDEX_BASELINE"] == "1"
        #expect(fake.fourthBeforeFirstFinished == !baseline)
        if !baseline {
            #expect(try store.counts().vectors == 96)
            #expect(try store.pendingCount() == 0)
            #expect(fake.inputs == 96)
        }
        print("SERVICE_REFILL_EVIDENCE: baseline=\(baseline) fourthBeforeFirstFinished=\(fake.fourthBeforeFirstFinished) calls=\(fake.calls) inputs=\(fake.inputs)")
    }
}
