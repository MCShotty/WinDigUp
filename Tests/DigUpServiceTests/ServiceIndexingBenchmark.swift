import Foundation
import Testing
import DigUpKit
@testable import digup

@Suite(.serialized)
struct ServiceIndexingBenchmark {
    final class Model: ParallelEmbedding, @unchecked Sendable {
        let maximumParallelJobs = 3
        let info = WorkerInfo(model: "service-benchmark", revision: "fixture", runtime: "fixture", dtype: "fixture",
                              dim: 768, textOnly: false, loadSeconds: nil)
        let lock = NSLock()
        enum Failure: Error { case missingFixtureIdentity }
        var calls = 0, inputs = 0, active = 0, peak = 0, syntheticDelayMs = 0
        func encode(_ values: [String], fixedNumber: Int? = nil) throws -> [[Float]] {
            var number: Int? = fixedNumber
            if number == nil, let first = values.first {
                for prefix in ["image-", "note-", "schedule_"] {
                    if let range = first.range(of: prefix) {
                        number = Int(first[range.upperBound...].prefix(while: \.isNumber))
                        break
                    }
                }
            }
            guard let number else { throw Failure.missingFixtureIdentity }
            let delay = number % 3 == 0 ? 60 : 6
            lock.lock()
            calls += 1; inputs += values.count; active += 1; peak = max(peak, active)
            syntheticDelayMs += delay
            lock.unlock()
            Thread.sleep(forTimeInterval: Double(delay) / 1000)
            lock.lock(); active -= 1; lock.unlock()
            return values.map { _ in [Float(1)] + [Float](repeating: 0, count: 767) }
        }
        func embedTexts(_ texts: [String]) throws -> [[Float]] { try encode(texts) }
        func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
            try encode(paths, fixedNumber: 0).map { Embedding(vector: $0, error: nil) }
        }
        func embedAudio(_ paths: [String]) throws -> [Embedding] {
            try encode(paths).map { Embedding(vector: $0, error: nil) }
        }
        func close() {}
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIGUP_SERVICE_BENCHMARK"] == "1"))
    func compareActualServiceWithImagesDocumentsAndMixedSources() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DigUpKitTests/Pictures/pattern-o6.jpg")
        let environment = ProcessInfo.processInfo.environment
        let requested = environment["DIGUP_SERVICE_WORKLOAD"]
        let count = max(1, min(5, environment["DIGUP_SERVICE_TRIALS"].flatMap(Int.init) ?? 5))
        let offset = environment["DIGUP_SERVICE_TRIAL_NUMBER"].flatMap(Int.init) ?? 0
        func order(_ file: URL, _ number: Int) throws {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(number))],
                                                  ofItemAtPath: file.path)
        }
        for workload in ["images", "documents", "mixed"] where requested == nil || requested == workload {
            var trials: [[String: Any]] = []
            for trial in 0..<count {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("digup-service-bench-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let documents = root.appendingPathComponent("files")
                let code = root.appendingPathComponent("code")
                try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
                let pictures = workload == "images" ? 96 : workload == "mixed" ? 32 : 0
                let notes = workload == "documents" ? 192 : workload == "mixed" ? 64 : 0
                let sources = workload == "mixed" ? 32 : 0
                for index in 0..<pictures {
                    let file = documents.appendingPathComponent("image-\(index).jpg")
                    try FileManager.default.copyItem(at: fixture, to: file)
                    try order(file, index)
                }
                for index in 0..<notes {
                    try "A railway timetable and photography document, item \(index).".write(
                        to: documents.appendingPathComponent("note-\(index).txt"), atomically: false, encoding: .utf8)
                    try order(documents.appendingPathComponent("note-\(index).txt"), index)
                }
                for index in 0..<sources {
                    try "def schedule_\(index)():\n    # Resolve a railway departure time.\n    return \(index)\n".write(
                        to: code.appendingPathComponent("schedule-\(index).py"), atomically: false, encoding: .utf8)
                    try order(code.appendingPathComponent("schedule-\(index).py"), index)
                }
                let directory = root.appendingPathComponent("index")
                let store = try IndexStore(directory: directory)
                let codeStore = try IndexStore(directory: directory, file: IndexStore.codeFile)
                let model = Model()
                let shared = SharedEmbedder { model }
                let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { try shared.embedder() })
                var codeOptions = IndexOptions(); codeOptions.code = true
                let codeIndexer = try Indexer(store: codeStore, options: codeOptions, makeEmbedder: { try shared.embedder() })
                let start = ProcessInfo.processInfo.systemUptime
                var previous = start, first: Double?
                var gaps: [Double] = []
                let service = IndexService(main: .init(store: store, indexer: indexer, roots: [documents], keepOnly: nil),
                    code: sources > 0 ? .init(store: codeStore, indexer: codeIndexer, roots: [code], keepOnly: nil) : nil,
                    folder: directory, model: shared, modelReady: { true }, backfill: true, newFilesLimit: 50, linger: 0,
                    output: { event in
                        if event["event"] as? String == "file" {
                            let now = ProcessInfo.processInfo.systemUptime
                            if first == nil { first = now - start }
                            gaps.append((now - previous) * 1000); previous = now
                        }
                    })
                #expect(service.serve(commandInput: false) == 0)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let vectors = try store.counts().vectors + codeStore.counts().vectors
                let files = pictures + notes + sources
                #expect(vectors == files)
                #expect(model.inputs == files)
                trials.append(["trial": offset + trial, "wallMs": elapsed * 1000, "filesPerSecond": Double(files) / elapsed,
                    "firstFileMs": (first ?? 0) * 1000, "completionGapsMs": gaps, "vectors": vectors,
                    "inferenceCalls": model.calls, "inputs": model.inputs, "peakActiveCalls": model.peak,
                    "syntheticDelayMs": model.syntheticDelayMs])
            }
            let report: [String: Any] = ["schemaVersion": 1, "workload": workload, "hardwareInference": false,
                "scope": "Actual IndexService: discovery, extraction, model-call scheduling, SQLite commits and cleanup",
                "cache": "Warm source cache after fixture creation; fresh indexes; synthetic model without startup cost",
                "modelDelay": "Identical image batches: 60 ms; text input number divisible by three: 60 ms, others 6 ms; fixed mtimes; three synthetic owners",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "logicalProcessors": ProcessInfo.processInfo.activeProcessorCount,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory, "trials": trials]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("INDEX_SERVICE_BENCHMARK: " + String(decoding: data, as: UTF8.self))
        }
    }
}
