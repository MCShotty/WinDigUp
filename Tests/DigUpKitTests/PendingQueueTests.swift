import Foundation
import Testing
@testable import DigUpKit

struct PendingQueueTests {
    func makeStore(_ root: URL, count: Int, kind: FileKind = .image) throws -> IndexStore {
        let store = try IndexStore(directory: root.appendingPathComponent("index"))
        try store.db.transaction {
            for index in 0..<count {
                try store.insert(Candidate(path: root.appendingPathComponent("files/item-\(index)").path,
                    kind: kind, size: 100, mtime: 1, inode: UInt64(index + 1), device: 1))
            }
        }
        return store
    }

    @Test func metadataPagesUseTheQueueRangeRatherThanTheFileStateIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, count: 80)
        let queue = try store.pendingQueue()
        defer { queue.close() }
        func plan(_ sql: String) throws -> [String] {
            var result: [String] = []
            try store.db.query("EXPLAIN QUERY PLAN " + sql, [.int(0), .text("pending"), .int(128)]) {
                result.append(try #require($0.text(3)))
            }
            return result
        }
        let original = try plan(queue.pageSQL.replacingOccurrences(of: "CROSS JOIN", with: "JOIN"))
        let bounded = try plan(queue.pageSQL)
        #expect(bounded.contains { $0.hasPrefix("SEARCH q ") && $0.contains("rowid>?") })
        #expect(bounded.contains { $0.hasPrefix("SEARCH f ") && $0.contains("rowid=?") })
        #expect(!bounded.contains { $0.contains("files_state") || $0.contains("TEMP B-TREE") })
        print("QUEUE_PAGE_QUERY_PLANS: original=\(original) bounded=\(bounded)")
    }

    @Test func pagesAndImageBatchesDoNotChangeTheFileLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, count: 80)
        let queue = try store.pendingQueue(limit: 25, pageSize: 16)
        defer { queue.close() }
        var ids: [Int64] = []
        var sizes: [Int] = []
        while let batch = try queue.takeBatch() {
            sizes.append(batch.files.count)
            ids += batch.files.map(\.id)
        }
        #expect(queue.total == 25)
        #expect(sizes == [8, 8, 8, 1])
        #expect(ids == Array(1...25).map(Int64.init))
        #expect(queue.peakBufferedRecords <= 16)
        #expect(try store.pendingCount() == 80)
    }

    @Test func priorityMembershipScopeAndStaleRowsRemainIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, count: 40, kind: .doc)
        let outside = try store.insert(Candidate(path: root.appendingPathComponent("offline/retained").path,
            kind: .doc, size: 10, mtime: 2, inode: 100, device: 1))
        store.scope = [root.appendingPathComponent("files").path]
        let queue = try store.pendingQueue(priorityIDs: [2, 39, outside], pageSize: 8)
        defer { queue.close() }
        try store.finish(2, state: "done")
        try store.delete(3)
        let first = try #require(try queue.take())
        #expect(first.file.id == 39)
        #expect(first.priority == 0)
        var seen: [Int64] = [39]
        while let entry = try queue.take() { seen.append(entry.file.id) }
        #expect(!seen.contains(2) && !seen.contains(3) && !seen.contains(outside))
        #expect(Set(seen).count == seen.count)
        #expect(try queue.remainingPriorityIDs() == [39])
        #expect(try store.files(under: [root.appendingPathComponent("offline").path]).map(\.id) == [outside])
    }

    @Test func stoppingAndRecreatingAQueueKeepsEveryUncommittedFilePending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, count: 300, kind: .doc)
        let first = try store.pendingQueue()
        _ = try first.takeBatch()
        first.close()
        first.close()
        let resumed = try store.pendingQueue()
        defer { resumed.close() }
        var count = 0
        while let batch = try resumed.takeBatch() { count += batch.files.count }
        #expect(count == 300)
        #expect(resumed.rows == 300)
        #expect(resumed.peakBufferedRecords <= 128)
        var version = 0
        try store.db.query("PRAGMA user_version") { version = Int($0.int(0)) }
        #expect(version == 5)
    }

    @Test func onlyAndZeroLimitsDoNotClaimUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root, count: 20)
        let empty = try store.pendingQueue(limit: 0)
        #expect(try empty.take() == nil)
        empty.close()
        let chosen = try store.pendingQueue(priorityIDs: [3, 7, 12], includePending: false, limit: 2)
        defer { chosen.close() }
        var ids: [Int64] = []
        while let entry = try chosen.take() { ids.append(entry.file.id) }
        #expect(ids == [3, 7])
        #expect(try store.pendingCount() == 20)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIGUP_QUEUE_BENCHMARK"] == "1"))
    func largeMetadataQueuePagesWithoutMaterializingTheCorpus() throws {
        for count in [100_000, 1_000_000] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try IndexStore(directory: root)
            try store.db.execute("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<\(count))
                INSERT INTO files(path,kind,size,mtime,inode,device)
                SELECT printf('/queue-fixture/%08d.txt',x),'doc',100,1,x,1 FROM n;
                """)
            let selected = try store.pendingQueue(priorityIDs: [1, Int64(count)], includePending: false)
            var selectedIDs: [Int64] = []
            while let entry = try selected.take() { selectedIDs.append(entry.file.id) }
            #expect(selectedIDs == [1, Int64(count)])
            print("QUEUE_PRIORITY_SCALE: corpus=\(count) selected=2 buildMs=\(selected.buildMs)")
            selected.close()
            let queue = try store.pendingQueue()
            defer { queue.close() }
            var received = 0
            while try queue.take() != nil {
                received += 1
                if received % 100_000 == 0 { print("QUEUE_SCALE_PROGRESS: \(received)/\(count)") }
            }
            #expect(received == count && queue.rows == count)
            #expect(queue.peakBufferedRecords <= 128)
            #expect(queue.pages <= count / 128 + 2)
            print("QUEUE_SCALE_EVIDENCE: records=\(count) buildMs=\(queue.buildMs) fetchMs=\(queue.fetchMs) pages=\(queue.pages) peakBufferedRecords=\(queue.peakBufferedRecords)")
        }
    }
}
