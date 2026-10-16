import Foundation
import Testing

@testable import DigUpKit

@Suite struct WorkerDeadlineTests {
    private func config(_ source: String) throws -> WorkerConfig {
        #if os(Windows)
            let separator: Character = ";"
            let name = "python.exe"
        #else
            let separator: Character = ":"
            let name = "python3"
        #endif
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: separator)
        let python = try #require(
            paths.map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) })
        var config = WorkerConfig(executable: python, arguments: ["-u", "-c", source])
        config.startupTimeout = 0.15
        config.requestTimeout = 0.15
        return config
    }
    @Test func stalledStartupIsBounded() throws {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try EmbeddingWorker(config("import time; time.sleep(10)"), textOnly: true)
            Issue.record("Worker unexpectedly became ready")
        } catch { #expect(String(describing: error).contains("timed out")) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
    }
    @Test func stalledReplyIsBounded() throws {
        let source = """
            import json,sys,time
            print(json.dumps({"ready":True,"info":{"model":"unit-test/no-model","revision":"test","runtime":"no-inference","dtype":"none","dim":768,"text_only":True}}),flush=True)
            sys.stdin.readline()
            time.sleep(10)
            """
        var options = try config(source)
        options.startupTimeout = 3
        let worker = try EmbeddingWorker(options, textOnly: true)
        defer { worker.close() }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try worker.embedTexts(["unit test"])
            Issue.record("Worker unexpectedly answered")
        } catch { #expect(String(describing: error).contains("timed out")) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
    }
}
