import Foundation
import Testing
import DigUpKit
@testable import digup

@Suite(.serialized)
struct ServiceSchedulingTests {
    enum FixtureError: Error { case drainedBeforeRefill }
    final class Model: ParallelEmbedding, @unchecked Sendable {
        let maximumParallelJobs: Int
        let blockFirst: Bool
        init(width: Int = 3, blockFirst: Bool = true) { maximumParallelJobs = width; self.blockFirst = blockFirst }
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
            if ordinal == 1 && blockFirst {
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

    func makeDocuments(_ root: URL, count: Int, code: Bool = false) throws -> URL {
        let folder = root.appendingPathComponent(code ? "code" : "documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<count {
            let contents = code ? "def useful_function_\(index)():\n    # Return a meaningful answer for the scheduling fixture.\n    return \(index)\n"
                : "A document describing a railway journey and its departure timetable. Number \(index)."
            try contents.write(to: folder.appendingPathComponent("item-\(index)." + (code ? "py" : "txt")),
                               atomically: false, encoding: .utf8)
        }
        return folder
    }

    @Test func fileAndCodeBacklogsCompleteWhileDiscoveryStreams() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = try makeDocuments(root, count: 64)
        let codeFolder = try makeDocuments(root, count: 64, code: true)
        let directory = root.appendingPathComponent("index")
        let mainStore = try IndexStore(directory: directory)
        let codeStore = try IndexStore(directory: directory, file: IndexStore.codeFile)
        let fake = Model(blockFirst: false)
        let shared = SharedEmbedder { fake }
        var codeOptions = IndexOptions()
        codeOptions.code = true
        let mainIndexer = try Indexer(store: mainStore, options: IndexOptions(), makeEmbedder: { try shared.embedder() })
        let codeIndexer = try Indexer(store: codeStore, options: codeOptions, makeEmbedder: { try shared.embedder() })
        var order: [Bool] = []
        let service = IndexService(main: .init(store: mainStore, indexer: mainIndexer, roots: [documents], keepOnly: nil),
            code: .init(store: codeStore, indexer: codeIndexer, roots: [codeFolder], keepOnly: nil),
            folder: directory, model: shared, modelReady: { true }, backfill: true, newFilesLimit: 50, linger: 0,
            output: { if $0["event"] as? String == "file" { order.append($0["code"] as? Bool ?? false) } })
        #expect(service.serve(commandInput: false) == 0)
        #expect(order.contains(false) && order.contains(true))
        #expect(try mainStore.counts().vectors == 64)
        #expect(try codeStore.counts().vectors == 64)
    }

    @Test(arguments: [1, 2, 3])
    func explicitCliLimitsRemainExactWithPagedInput(width: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = try makeDocuments(root, count: 140)
        let store = try IndexStore(directory: root.appendingPathComponent("index"))
        let fake = Model(width: width, blockFirst: false)
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { fake })
        _ = try indexer.sync([documents])
        _ = try indexer.run(limit: 0)
        #expect(fake.calls == 0)
        _ = try indexer.run(limit: 17)
        #expect(try store.counts().vectors == 17)
        #expect(try store.pendingCount() == 123)
        #expect(indexer.lastPipeline?.inferenceWorkers == width)
        #expect((indexer.lastPipeline?.peakResidentJobs ?? 0) <= (width == 1 ? 2 : width * 2 + 2))
    }

    @Test func pauseAfterPublicationRetainsPendingWorkAndResumeDoesNotDuplicateVectors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = try makeDocuments(root, count: 64)
        let directory = root.appendingPathComponent("index")
        let store = try IndexStore(directory: directory)
        let fake = Model(blockFirst: false)
        let shared = SharedEmbedder { fake }
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { try shared.embedder() })
        var service: IndexService?
        service = IndexService(main: .init(store: store, indexer: indexer, roots: [documents], keepOnly: nil),
            code: nil, folder: directory, model: shared, modelReady: { true },
            backfill: true, newFilesLimit: 50, linger: 0,
            output: { if $0["event"] as? String == "file" { service?.accept("backfill off") } })
        #expect(service?.serve(commandInput: false) == 0)
        #expect(try store.counts().vectors == 1)
        #expect(try store.pendingCount() == 63)
        service = nil
        let resumedModel = Model(blockFirst: false)
        let resumedShared = SharedEmbedder { resumedModel }
        let resumedIndexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { try resumedShared.embedder() })
        let resumed = IndexService(main: .init(store: store, indexer: resumedIndexer, roots: [documents], keepOnly: nil),
            code: nil, folder: directory, model: resumedShared, modelReady: { true },
            backfill: true, newFilesLimit: 50, linger: 0, output: { _ in })
        #expect(resumed.serve(commandInput: false) == 0)
        #expect(try store.counts().vectors == 64)
        #expect(try store.pendingCount() == 0)
        #expect(resumedModel.inputs == 63)
    }

    @Test(arguments: [2, 64])
    func smallNewDemandAndBackfillPolicyRemainSeparate(count: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = try makeDocuments(root, count: count)
        let directory = root.appendingPathComponent("index")
        let store = try IndexStore(directory: directory)
        let fake = Model(blockFirst: false)
        let shared = SharedEmbedder { fake }
        let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { try shared.embedder() })
        let service = IndexService(main: .init(store: store, indexer: indexer, roots: [documents], keepOnly: nil),
            code: nil, folder: directory, model: shared, modelReady: { true },
            backfill: false, newFilesLimit: 50, linger: 0, output: { _ in })
        #expect(service.serve(commandInput: false) == 0)
        #expect(try store.counts().vectors == (count <= 50 ? count : 0))
        #expect(fake.calls == (count <= 50 ? count : 0))
    }

}
