import Foundation
import Testing
@testable import DigUpKit

struct IndexPipelineBenchmarkTests {
    final class TimedEmbedder: ParallelEmbedding, @unchecked Sendable {
        let maximumParallelJobs = 3
        let info = WorkerInfo(model: "fixture", revision: "fixture", runtime: "fixture", dtype: "fixture",
                              dim: 768, textOnly: false, loadSeconds: nil)
        let lock = NSLock()
        var active = 0
        var peak = 0
        var calls = 0
        var durations: [Double] = []

        func embedTexts(_ texts: [String]) throws -> [[Float]] {
            let start = ProcessInfo.processInfo.systemUptime
            lock.lock()
            active += 1
            peak = max(peak, active)
            let ordinal = calls
            calls += 1
            lock.unlock()
            Thread.sleep(forTimeInterval: ordinal % 6 == 0 ? 0.12 : 0.012)
            lock.lock()
            active -= 1
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            lock.unlock()
            return texts.map { _ in [Float(1)] + [Float](repeating: 0, count: 767) }
        }
        func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] { fatalError("Text fixture") }
        func embedAudio(_ paths: [String]) throws -> [Embedding] { fatalError("Text fixture") }
        func close() {}
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIGUP_PIPELINE_BENCHMARK"] == "1"))
    func compareActualIndexerScheduling() throws {
        var trials: [[String: Any]] = []
        for trial in 0..<5 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("digup-pipeline-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = root.appendingPathComponent("documents")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            for index in 0..<96 {
                let text = "Document \(index) about railway timetables and photography, prepared for the indexing fixture."
                let url = files.appendingPathComponent(String(format: "document-%03d.txt", index))
                try text.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 - Double(index))],
                                                      ofItemAtPath: url.path)
            }
            let store = try IndexStore(directory: root.appendingPathComponent("index"))
            let model = TimedEmbedder()
            let indexer = try Indexer(store: store, options: IndexOptions(), makeEmbedder: { model })
            _ = try indexer.sync([files])
            var order: [String] = []
            var intervals: [Double] = []
            let start = ProcessInfo.processInfo.systemUptime
            var previous = start
            let states = try indexer.run(onEvent: { event in
                let now = ProcessInfo.processInfo.systemUptime
                intervals.append((now - previous) * 1000)
                previous = now
                order.append(URL(fileURLWithPath: event.path).lastPathComponent)
                Thread.sleep(forTimeInterval: 0.004)
            })
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            #expect(states["done"] == 96)
            #expect(try store.counts().vectors == 96)
            #expect(model.calls == 96)
            #expect(order == (0..<96).map { String(format: "document-%03d.txt", $0) })
            trials.append(["trial": trial, "wallMs": elapsed * 1000, "filesPerSecond": 96 / elapsed,
                           "inferenceCalls": model.calls, "peakActiveCalls": model.peak,
                           "completionGapsMs": intervals, "inferenceCallsMs": model.durations])
        }
        let report: [String: Any] = [
            "schemaVersion": 1, "workload": "96 short text files, fresh SQLite, three synthetic owners, five trials",
            "cache": "Files written and crawled immediately before each run; OS cache warm; fresh vectors",
            "inferenceDelay": "Every sixth call 120 ms, others 12 ms; 4 ms commit observer",
            "hardwareInference": false, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "logicalProcessors": ProcessInfo.processInfo.activeProcessorCount,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "trials": trials
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let record = "INDEX_PIPELINE_BENCHMARK: " + String(decoding: data, as: UTF8.self) + "\n"
        if let destination = ProcessInfo.processInfo.environment["DIGUP_PIPELINE_REPORT"] {
            // swift test may multiplex child stdout with its own progress output.
            // Keep the measured report outside those shared streams.
            try record.write(to: URL(fileURLWithPath: destination), atomically: true, encoding: .utf8)
        } else {
            print(record, terminator: "")
        }
    }
}
