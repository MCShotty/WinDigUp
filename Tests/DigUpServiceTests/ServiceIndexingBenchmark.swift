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
        var calls = 0, inputs = 0, active = 0, peak = 0
        func encode(_ count: Int) -> [[Float]] {
            lock.lock()
            let ordinal = calls
            calls += 1; inputs += count; active += 1; peak = max(peak, active)
            lock.unlock()
            Thread.sleep(forTimeInterval: ordinal % 3 == 0 ? 0.06 : 0.006)
            lock.lock(); active -= 1; lock.unlock()
            return (0..<count).map { _ in [Float(1)] + [Float](repeating: 0, count: 767) }
        }
        func embedTexts(_ texts: [String]) throws -> [[Float]] { encode(texts.count) }
        func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
            encode(paths.count).map { Embedding(vector: $0, error: nil) }
        }
        func embedAudio(_ paths: [String]) throws -> [Embedding] {
            encode(paths.count).map { Embedding(vector: $0, error: nil) }
        }
        func close() {}
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIGUP_SERVICE_BENCHMARK"] == "1"))
    func compareActualServiceWithImagesDocumentsAndMixedSources() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DigUpKitTests/Pictures/pattern-o6.jpg")
        for workload in ["images", "documents", "mixed"] {
            var trials: [[String: Any]] = []
            for trial in 0..<5 {
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
                    try FileManager.default.copyItem(at: fixture, to: documents.appendingPathComponent("image-\(index).jpg"))
                }
                for index in 0..<notes {
                    try "A railway timetable and photography document, item \(index).".write(
                        to: documents.appendingPathComponent("note-\(index).txt"), atomically: false, encoding: .utf8)
                }
                for index in 0..<sources {
                    try "def schedule_\(index)():\n    # Resolve a railway departure time.\n    return \(index)\n".write(
                        to: code.appendingPathComponent("schedule-\(index).py"), atomically: false, encoding: .utf8)
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
                trials.append(["trial": trial, "wallMs": elapsed * 1000, "filesPerSecond": Double(files) / elapsed,
                    "firstFileMs": (first ?? 0) * 1000, "completionGapsMs": gaps, "vectors": vectors,
                    "inferenceCalls": model.calls, "inputs": model.inputs, "peakActiveCalls": model.peak])
            }
            let report: [String: Any] = ["schemaVersion": 1, "workload": workload, "hardwareInference": false,
                "scope": "Actual IndexService: discovery, extraction, model-call scheduling, SQLite commits and cleanup",
                "cache": "Warm source cache after fixture creation; fresh indexes; synthetic model without startup cost",
                "modelDelay": "Every third call 60 ms, others 6 ms; three synthetic inference owners",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "logicalProcessors": ProcessInfo.processInfo.activeProcessorCount,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory, "trials": trials]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("INDEX_SERVICE_BENCHMARK: " + String(decoding: data, as: UTF8.self))
        }
    }
}
