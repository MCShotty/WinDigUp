import Foundation
import Testing
@testable import DigUpKit
@testable import digup

@Suite(.serialized)
struct SearchNameRefreshTests {
    enum Failure: Error { case timedOut, inferenceMustRemainStopped }
    final class Mailbox: @unchecked Sendable {
        private let condition = NSCondition()
        private var unread: [[String: Any]] = []
        private var history: [[String: Any]] = []
        func receive(_ value: [String: Any]) {
            condition.lock(); unread.append(value); history.append(value); condition.broadcast(); condition.unlock()
        }
        func take(where predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(5)
            while true {
                if let index = unread.firstIndex(where: predicate) { return unread.remove(at: index) }
                guard condition.wait(until: deadline) else { throw Failure.timedOut }
            }
        }
        func reply(_ id: Int) throws -> [String: Any] { try take { $0["id"] as? Int == id } }
        func events(_ state: String) -> Int {
            condition.lock(); defer { condition.unlock() }
            return history.filter { $0["event"] as? String == "search_index" && $0["state"] as? String == state }.count
        }
        var encoderEvents: Int {
            condition.lock(); defer { condition.unlock() }
            return history.filter { $0["event"] as? String == "encoder" }.count
        }
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("digup-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderSelection.realPath(root.path), isDirectory: true)
    }
    func idle(_ service: SearchService, _ mailbox: Mailbox) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            service.admit(SearchMessage(["op": "status", "id": 90000]))
            let reply = try mailbox.reply(90000)
            if reply["refreshing"] as? Bool == false { return reply }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw Failure.timedOut
    }

    @Test func blockedDiscoveryPublishesNamesKindsAndExactCollisionsWithoutAnEncoder() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("files"), later = files.appendingPathComponent("later")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        let name = files.appendingPathComponent("Bluetooth.txt")
        try "A useful local document.".write(to: name, atomically: false, encoding: .utf8)
        for number in 0..<63 {
            try "A useful local document.".write(to: files.appendingPathComponent("note-\(number).txt"),
                atomically: false, encoding: .utf8)
        }
        try "A later document.".write(to: later.appendingPathComponent("later.txt"), atomically: false, encoding: .utf8)
        let directory = root.appendingPathComponent("index")
        let writer = try IndexStore(directory: directory)
        let mailbox = Mailbox()
        let search = try SearchService(index: directory, baseIndex: directory, roots: [files.path],
            skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in true }, onReply: { mailbox.receive($0) })
        defer { search.stop() }
        search.admit(SearchMessage(["op": "refresh_names", "id": 1]))
        _ = try mailbox.reply(1)
        _ = try mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "words_ready" }
        _ = try idle(search, mailbox) // A pre-existing empty helper snapshot, before the scan.
        let blocked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let attempts = Counter()
        let model = SharedEmbedder { attempts.increment(); throw Failure.inferenceMustRemainStopped }
        let indexer = try Indexer(store: writer, options: IndexOptions(), makeEmbedder: { try model.embedder() })
        var checked = false, failure: (any Error)?
        let service = IndexService(main: .init(store: writer, indexer: indexer, roots: [files], keepOnly: nil),
            code: nil, folder: directory, model: model, modelReady: { false },
            backfill: false, newFilesLimit: 0, linger: 0,
            output: { event in
                guard event["event"] as? String == "scan_batch", !checked else { return }
                checked = true
                defer { release.signal() }
                do {
                    guard blocked.wait(timeout: .now() + 5) == .success else { throw Failure.timedOut }
                    search.admit(SearchMessage(["op": "refresh_names", "id": 2]))
                    _ = try mailbox.reply(2)
                    _ = try mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "words_ready" }
                    _ = try idle(search, mailbox)
                    for (id, kinds, expected) in [(3, ["doc"], 1), (4, ["image"], 0)] {
                        search.admit(SearchMessage(["op": "search", "id": id, "q": "Bluetooth",
                            "meaning": false, "kinds": kinds, "session": "blocked-scan", "generation": 17]))
                        let reply = try mailbox.reply(id)
                        let hits = try #require(reply["hits"] as? [[String: Any]])
                        #expect(hits.count == expected)
                        if expected == 1 { #expect(hits.first?["path"] as? String == name.path) }
                        #expect(reply["exact_filename_known"] as? Bool == true)
                        #expect(reply["exact_filename"] as? Bool == true)
                        #expect(reply["session"] as? String == "blocked-scan")
                        #expect(reply["generation"] as? Int == 17)
                    }
                    #expect(try idle(search, mailbox)["encoder"] as? String == "stopped")
                } catch { failure = error }
            }, beforeScanFolder: { folder in
                if folder.lastPathComponent == "later" {
                    blocked.signal()
                    _ = release.wait(timeout: .now() + 10)
                }
            })
        #expect(service.serve(commandInput: false) == 0)
        if let failure { throw failure }
        #expect(checked)
        #expect(attempts.value == 0)
        #expect(mailbox.encoderEvents == 0)
        #expect(mailbox.events("ready") == 0)
        print("STREAMED_NAMES_EVIDENCE: blockedDiscovery=true exactFilename=true kindFilter=true encoderStarts=0")
    }


    final class QueueMarker: @unchecked Sendable {
        let key = DispatchSpecificKey<String>()
    }
    final class Probe: @unchecked Sendable {
        let onDeinit: @Sendable () -> Void
        init(_ onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
        deinit { onDeinit() }
    }
    final class Owner: @unchecked Sendable {
        var value: Probe
        init(_ value: Probe) { self.value = value }
    }
    final class Disposal: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: String?
        func record(_ value: String?) { lock.lock(); queue = value; lock.unlock() }
        var recorded: String? { lock.lock(); defer { lock.unlock() }; return queue }
    }

    @Test func snapshotContentsAreDestroyedByRetirementWhileLexicalJobKeepsTheContainer() throws {
        let marker = QueueMarker(), disposal = Disposal()
        let lexical = DispatchQueue(label: "digup.test.lexical")
        let retirement = DispatchQueue(label: "digup.test.retirement")
        lexical.setSpecific(key: marker.key, value: "lexical")
        retirement.setSpecific(key: marker.key, value: "retirement")
        let disposed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let owner = Owner(Probe {
            disposal.record(DispatchQueue.getSpecific(key: marker.key))
            disposed.signal()
        })
        lexical.async {
            let retired = SearchRetirement(owner.value)
            owner.value = Probe {} // No lexical owner reference remains to the transferred resource.
            retirement.async { retired.release() }
            _ = disposed.wait(timeout: .now() + 3)
            // Deliberately keep the container alive on the lexical queue after the disposal task runs.
            withExtendedLifetime(retired) {}
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 5) == .success)
        #expect(disposal.recorded == "retirement")
    }

    @Test func coalescedMetadataRefreshDoesNotReplaceLoadedVectorsOrWakeAnEncoder() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try IndexStore(directory: root.appendingPathComponent("index"))
        for number in 0..<2000 {
            try writer.insert(Candidate(path: root.appendingPathComponent("note-\(number).txt").path,
                kind: .doc, size: 10, mtime: 1, inode: UInt64(number + 1), device: 1))
        }
        var vector = [Float16](repeating: 0, count: 768); vector[0] = 1
        let data = vector.withUnsafeBytes { Data($0) }
        try writer.db.run("UPDATE segments SET vec=? WHERE id=(SELECT min(id) FROM segments)", [.blob(data)])
        let mailbox = Mailbox()
        let search = try SearchService(index: writer.directory, baseIndex: writer.directory, roots: [root.path],
            skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in true }, onReply: { mailbox.receive($0) })
        defer { search.stop() }
        search.requestRefresh(vectors: true) // Cached vectors load independently of the neural encoder.
        _ = try mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "ready" }
        _ = try idle(search, mailbox)
        let next = root.appendingPathComponent("Sound.txt").path
        try writer.insert(Candidate(path: next, kind: .doc, size: 10, mtime: 1, inode: 3001, device: 1))
        for id in 1...100 { search.admit(SearchMessage(["op": "refresh_names", "id": id])) }
        for id in 1...100 { _ = try mailbox.reply(id) }
        #expect(try idle(search, mailbox)["encoder"] as? String == "stopped")
        search.admit(SearchMessage(["op": "search", "id": 101, "q": "Sound", "meaning": false, "kinds": ["doc"]]))
        let reply = try mailbox.reply(101)
        #expect((reply["hits"] as? [[String: Any]])?.first?["path"] as? String == next)
        #expect(reply["exact_filename"] as? Bool == true)
        #expect(mailbox.events("ready") == 1)
        #expect(mailbox.encoderEvents == 0)
    }
}
