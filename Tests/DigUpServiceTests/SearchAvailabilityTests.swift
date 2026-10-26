import Foundation
import Testing
import DigUpKit
@testable import digup

@Suite(.serialized)
struct SearchAvailabilityTests {
    final class Probes: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        func delayed(_ path: String) -> Bool {
            lock.lock(); calls += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.2)
            return !path.hasSuffix("report-missing.txt")
        }
    }

    func fixture() throws -> (URL, IndexStore, Searcher) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("digup-availability-\(UUID().uuidString)")
        let store = try IndexStore(directory: root.appendingPathComponent("index"))
        for (number, name) in ["report.txt", "report-missing.txt"].enumerated() {
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
        #expect(elapsed >= 500)
        #expect((reply["hits"] as? [[String: Any]])?.count == 1)
        print("AVAILABILITY_EVIDENCE: synchronous=true elapsedMs=\(elapsed) probes=\(probes.calls) injectedProbeMs=200")
    }
}
