import Foundation
import Testing
import DigUpKit
@testable import digup

@Suite(.serialized)
struct SearchAvailabilityTests {
    final class Probes: @unchecked Sendable {
        let lock = NSLock()
        private var recordedCalls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return recordedCalls }
        func delayed(_ path: String) -> Bool {
            lock.lock(); recordedCalls += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.2)
            return !path.hasSuffix("report-missing.txt")
        }
    }

    func fixture() throws -> (URL, IndexStore, Searcher) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("digup-availability-\(UUID().uuidString)")
        let store = try IndexStore(directory: root.appendingPathComponent("index"))
        for (number, name) in ["report.txt", "private/report-missing.txt"].enumerated() {
            let id = Int64(number + 1)
            try store.db.run("INSERT INTO files(id,path,kind,size,mtime,inode,device,state) VALUES(?,?,'doc',1,1,?,1,'done')",
                             [.int(id), .text(root.appendingPathComponent(name).path), .int(id)])
            try store.db.run("INSERT INTO segments(id,file,kind,modality) VALUES(?,?,'name','none')", [.int(id), .int(id)])
            try store.db.run("INSERT INTO fts(rowid,name,body) VALUES(?,?,'report')", [.int(id), .text(name)])
        }
        return (root, store, try Searcher(store: store, loadVectors: false, loadNames: true))
    }

    @Test func delayedProbeEvidence() throws {
        let (root, store, searcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probes = Probes()
        let service = try SearchService(index: store.directory, baseIndex: store.directory,
            roots: [], skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { probes.delayed($0) })
        let began = ProcessInfo.processInfo.systemUptime
        let reply = try service.fileSearch(["q": "report", "meaning": false], in: searcher, vector: nil, source: nil)
        let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let hits = try #require(reply["hits"] as? [[String: Any]])
        #expect(elapsed < 150)
        #expect(hits.count == 2)
        #expect(reply["exact_filename"] as? Bool == true)
        #expect(hits.allSatisfy { $0["availability"] as? String == "unknown" })
        Thread.sleep(forTimeInterval: 0.5)
        let checked = try service.fileSearch(["q": "report", "meaning": false], in: searcher, vector: nil, source: nil)
        let known = try #require(checked["hits"] as? [[String: Any]])
        #expect(known.count == 2)
        #expect(known.filter { $0["availability"] as? String == "available" }.count == 1)
        #expect(known.filter { $0["availability"] as? String == "unknown" }.count == 1)
        print("AVAILABILITY_EVIDENCE: synchronous=false elapsedMs=\(elapsed) probes=\(probes.calls) injectedProbeMs=200")
    }

    func waitFor(_ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(condition())
    }

    @Test func blockedProbesHaveBoundedOwnersAndPendingWork() throws {
        let gate = DispatchSemaphore(value: 0)
        let cache = FileAvailability(probe: { _ in gate.wait(); return true })
        for number in 0..<5000 { #expect(cache.observation("path-\(number)").state == "unknown") }
        #expect(cache.snapshot["active"] as? Int == 2)
        #expect(cache.snapshot["queued"] as? Int == 256)
        cache.stop()
        gate.signal(); gate.signal()
        try waitFor { cache.snapshot["active"] as? Int == 0 }
        #expect(cache.snapshot["queued"] as? Int == 0)
        #expect(cache.snapshot["cached"] as? Int == 0)
    }

    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value = 10.0
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ delta: Double) { lock.lock(); value += delta; lock.unlock() }
    }

    @Test func staleChecksAreExplicitAndCacheSizeIsBounded() throws {
        let clock = Clock()
        let cache = FileAvailability(cacheLimit: 2, clock: { clock.read() }, probe: { _ in true })
        defer { cache.stop() }
        #expect(cache.observation("one").state == "unknown")
        try waitFor { cache.snapshot["completed"] as? Int == 1 }
        #expect(cache.observation("one").state == "available")
        clock.advance(6)
        let stale = cache.observation("one")
        #expect(stale.state == "unknown" && stale.stale)
        #expect(stale.ageMilliseconds == 6000)
        try waitFor { cache.snapshot["completed"] as? Int == 2 }
        _ = cache.observation("two")
        _ = cache.observation("three")
        try waitFor { cache.snapshot["completed"] as? Int == 4 }
        #expect(cache.snapshot["cached"] as? Int == 2)
    }

    @Test func exclusionsRemainImmediateAndAreNotProbed() throws {
        let (root, store, searcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probes = Probes()
        let service = try SearchService(index: store.directory, baseIndex: store.directory,
            roots: [root.path], skipped: [root.appendingPathComponent("private").path], types: [],
            codeRoots: [], codeSkipped: [], idleSeconds: 300, fileExists: { probes.delayed($0) })
        let reply = try service.fileSearch(["q": "report", "meaning": false], in: searcher, vector: nil, source: nil)
        #expect((reply["hits"] as? [[String: Any]])?.count == 1)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(probes.calls == 1)
        #expect(reply["exact_filename"] as? Bool == true)
    }

    @Test func clearingWhileAProbeRunsCannotRepublishAnOlderObservation() throws {
        let gate = DispatchSemaphore(value: 0)
        let cache = FileAvailability(concurrency: 1, probe: { _ in gate.wait(); return true })
        #expect(cache.observation("one").state == "unknown")
        cache.clear()
        gate.signal()
        try waitFor { cache.snapshot["completed"] as? Int == 1 }
        #expect(cache.snapshot["cached"] as? Int == 0)
        cache.stop()
    }

    @Test func unavailableOrInaccessibleFilesRemainUnknownAndKeepExactCollisions() throws {
        let (root, store, searcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try SearchService(index: store.directory, baseIndex: store.directory,
            roots: [], skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in false })
        _ = try service.fileSearch(["q": "report", "meaning": false], in: searcher, vector: nil, source: nil)
        Thread.sleep(forTimeInterval: 0.05)
        let checked = try service.fileSearch(["q": "report", "meaning": false], in: searcher, vector: nil, source: nil)
        let hits = try #require(checked["hits"] as? [[String: Any]])
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0["availability"] as? String == "unknown" })
        #expect(checked["exact_filename"] as? Bool == true)
    }

    @Test func explicitEmptyShellScopeCannotSearchRetainedRowsButCliStillCan() throws {
        let (root, store, searcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try SearchService(index: store.directory, baseIndex: store.directory,
            roots: [], skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in true })
        let scoped = try service.fileSearch(["q":"report", "file_scope":["version":1,"roots":[],"skipped":[],"types":[]]],
                                           in: searcher, vector: nil, source: nil)
        #expect((scoped["hits"] as? [[String: Any]])?.isEmpty == true)
        #expect(scoped["scope_empty"] as? Bool == true)
        #expect(scoped["file_scope_version"] as? Int == 1)
        let cli = try service.fileSearch(["q":"report"], in: searcher, vector: nil, source: nil)
        #expect((cli["hits"] as? [[String: Any]])?.count == 2)
    }

    @Test func explicitRequestScopeWinsBeforeTheFoldersControlMessageArrives() throws {
        let (root, store, searcher) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try SearchService(index: store.directory, baseIndex: store.directory,
            roots: [root.path], skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in true })
        let scoped = try service.fileSearch(["q":"report", "file_scope":["version":1,
            "roots":[root.appendingPathComponent("private").path],"skipped":[],"types":[]]],
            in: searcher, vector: nil, source: nil)
        let hits = try #require(scoped["hits"] as? [[String: Any]])
        #expect(hits.count == 1)
        #expect(scoped["file_scope_version"] as? Int == 1)
        #expect((hits.first?["path"] as? String)?.contains("/private/") == true)
        #expect(throws: (any Error).self) {
            _ = try service.fileSearch(["q":"report","file_scope":["version":2,"roots":[]]],
                                       in: searcher, vector: nil, source: nil)
        }
    }
}
