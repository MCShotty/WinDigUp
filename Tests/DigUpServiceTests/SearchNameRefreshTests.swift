import Foundation
import Testing
@testable import DigUpKit
@testable import digup

@Suite(.serialized)
struct SearchNameRefreshTests {
    typealias Fixture = SearchServiceFixture
    typealias Mailbox = Fixture.Mailbox

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

    @Test func snapshotContentsAreDestroyedByRetirementWhileLexicalJobKeepsTheContainer() async throws {
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
        try await Fixture.signal(finished, timeout: 5)
        #expect(disposal.recorded == "retirement")
    }

    @Test func coalescedMetadataRefreshDoesNotReplaceLoadedVectorsOrWakeAnEncoder() async throws {
        let root = try Fixture.temporary()
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
        _ = try await mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "ready" }
        _ = try await Fixture.idle(search, mailbox)
        let next = root.appendingPathComponent("Sound.txt").path
        try writer.insert(Candidate(path: next, kind: .doc, size: 10, mtime: 1, inode: 3001, device: 1))
        for id in 1...100 { search.admit(SearchMessage(["op": "refresh_names", "id": id])) }
        for id in 1...100 { _ = try await mailbox.reply(id) }
        #expect(try await Fixture.idle(search, mailbox)["encoder"] as? String == "stopped")
        search.admit(SearchMessage(["op": "search", "id": 101, "q": "Sound", "meaning": false, "kinds": ["doc"]]))
        let reply = try await mailbox.reply(101)
        #expect((reply["hits"] as? [[String: Any]])?.first?["path"] as? String == next)
        #expect(reply["exact_filename"] as? Bool == true)
        #expect(mailbox.events("ready") == 1)
        #expect(mailbox.encoderEvents == 0)
    }

    @Test func heldAvailabilityProbesAndConcurrentHelpersCannotStarveMetadataHandoffs() async throws {
        let root = try Fixture.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DispatchSemaphore(value: 0)
        let started = Fixture.Counter()
        var writers: [IndexStore] = [], services: [SearchService] = [], mailboxes: [Mailbox] = []
        defer {
            services.forEach { $0.stop() }
            gate.signal(); gate.signal()
        }
        for number in 0..<4 {
            let writer = try IndexStore(directory: root.appendingPathComponent("index-\(number)"))
            for item in 0..<2 {
                try writer.insert(Candidate(path: root.appendingPathComponent("note-\(item).txt").path,
                    kind: .doc, size: 10, mtime: 1, inode: UInt64(item + 1), device: 1))
            }
            let mailbox = Mailbox()
            let service = try SearchService(index: writer.directory, baseIndex: writer.directory, roots: [root.path],
                skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
                fileExists: { _ in
                    if number == 0 { started.increment(); gate.wait() }
                    return true
                }, onReply: { mailbox.receive($0) })
            writers.append(writer); services.append(service); mailboxes.append(mailbox)
        }
        services[0].admit(SearchMessage(["op": "search", "id": 1, "q": "note", "meaning": false]))
        #expect((try await mailboxes[0].reply(1)["hits"] as? [[String: Any]])?.count == 2)
        let deadline = Date().addingTimeInterval(3)
        while started.value < 2 && Date() < deadline { try await Fixture.delay(0.005) }
        #expect(started.value == 2)
        for number in 0..<services.count {
            try writers[number].insert(Candidate(path: root.appendingPathComponent("fresh-\(number).txt").path,
                kind: .doc, size: 10, mtime: 1, inode: 3, device: 1))
            for id in 2...20 { services[number].admit(SearchMessage(["op": "refresh_names", "id": id])) }
        }
        for number in 0..<services.count {
            for id in 2...20 { #expect(try await mailboxes[number].reply(id)["ok"] as? Bool == true) }
            _ = try await Fixture.idle(services[number], mailboxes[number])
            services[number].admit(SearchMessage(["op": "search", "id": 21,
                "q": "fresh-\(number)", "meaning": false, "kinds": ["doc"]]))
            let reply = try await mailboxes[number].reply(21)
            #expect((reply["hits"] as? [[String: Any]])?.count == 1)
            #expect(reply["exact_filename"] as? Bool == true)
            #expect(mailboxes[number].encoderEvents == 0)
        }
        // The two simulated network probes remain held until AFTER every metadata/query reply completed.
        #expect(started.value == 2)
        print("REFRESH_HANDOFF_EVIDENCE: helpers=4 heldProbes=2 allControlAndSearchRepliesCompleted=true encoderStarts=0")
    }

    @Test func shutdownCancelsQueuedRepliesWithoutWaitingForAPublicationOwner() async throws {
        let root = try Fixture.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try IndexStore(directory: root.appendingPathComponent("index"))
        try writer.insert(Candidate(path: root.appendingPathComponent("closing.txt").path,
            kind: .doc, size: 10, mtime: 1, inode: 1, device: 1))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0), mailbox = Mailbox()
        let service = try SearchService(index: writer.directory, baseIndex: writer.directory, roots: [root.path],
            skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in true }, onReply: { mailbox.receive($0) })
        defer { service.stop(); release.signal() }
        service.lexical.submit(key: "held-publication-owner") {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            returned.signal()
        }
        try await Fixture.signal(entered)
        service.requestRefresh(vectors: true)
        service.admit(SearchMessage(["op": "search", "id": 70, "q": "closing", "meaning": false,
            "session": "closing-view", "generation": 1]))
        service.stop()
        let reply = try await mailbox.reply(70)
        #expect(reply["status"] as? String == "superseded")
        #expect((reply["hits"] as? [[String: Any]])?.isEmpty == true)
        // Cancellation completed while the owner was still deliberately held.
        #expect(!Fixture.isSignaled(returned))
        release.signal()
        try await Fixture.signal(returned)
        #expect(mailbox.events("ready") == 0)
        #expect(mailbox.encoderEvents == 0)
    }

    @Test func idleInvalidationRejectsDelayedVectorsAndRetainsLaterForegroundIntent() async throws {
        let root = try Fixture.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try IndexStore(directory: root.appendingPathComponent("index"))
        try writer.insert(Candidate(path: root.appendingPathComponent("initial.txt").path,
            kind: .doc, size: 10, mtime: 1, inode: 1, device: 1))
        try Fixture.seedVector(writer)
        let mailbox = Mailbox(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let service = try SearchService(index: writer.directory, baseIndex: writer.directory, roots: [root.path],
            skipped: [], types: [], codeRoots: [], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in true }, onReply: { mailbox.receive($0) })
        defer { service.stop(); release.signal() }
        service.retrieval.submit(key: "held-vector-owner") {
            entered.signal(); _ = release.wait(timeout: .now() + 5); returned.signal()
        }
        try await Fixture.signal(entered)
        service.requestRefresh(vectors: true)
        _ = try await mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "words_ready" }
        try await Fixture.waitUntil { service.retrieval.pendingCount > 0 }
        let idleEpoch = service.cancelIdleVectors()
        service.releaseVectors(olderThan: idleEpoch)
        try writer.insert(Candidate(path: root.appendingPathComponent("fresh.txt").path,
            kind: .doc, size: 10, mtime: 1, inode: 2, device: 1))
        service.admit(SearchMessage(["op": "refresh_names", "id": 80]))
        _ = try await mailbox.reply(80)
        service.admit(SearchMessage(["op": "search", "id": 81, "q": "initial", "meaning": false]))
        #expect((try await mailbox.reply(81)["hits"] as? [[String: Any]])?.count == 1)
        #expect(!Fixture.isSignaled(returned))
        release.signal()
        try await Fixture.signal(returned)
        _ = try await mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "words_ready" }
        let idle = try await Fixture.idle(service, mailbox)
        #expect(idle["vector_snapshot_loaded"] as? Bool == false)
        #expect(mailbox.events("ready") == 0)
        service.admit(SearchMessage(["op": "search", "id": 82, "q": "fresh", "meaning": false, "kinds": ["doc"]]))
        #expect((try await mailbox.reply(82)["hits"] as? [[String: Any]])?.count == 1)

        // Delay the old idle release until a new explicit vector request has already published.
        let olderIdle = service.cancelIdleVectors()
        service.requestRefresh(vectors: true)
        _ = try await mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "ready" }
        service.releaseVectors(olderThan: olderIdle)
        let released = DispatchSemaphore(value: 0)
        service.retrieval.submit(key: "after-delayed-idle", foreground: false) { released.signal() }
        try await Fixture.signal(released)
        let fresh = try await Fixture.idle(service, mailbox)
        #expect(fresh["vector_snapshot_loaded"] as? Bool == true)
        #expect(fresh["snapshot_revision"] as? UInt64 == 1)
        let finalIdle = service.cancelIdleVectors()
        service.admit(SearchMessage(["op": "folders", "id": 83, "code_roots": [root.appendingPathComponent("code").path]]))
        _ = try await mailbox.reply(83)
        _ = try await Fixture.idle(service, mailbox)
        #expect(mailbox.events("ready") == 1)
        service.releaseVectors(olderThan: finalIdle)
        let drained = DispatchSemaphore(value: 0)
        service.retrieval.submit(key: "after-final-idle", foreground: false) { drained.signal() }
        try await Fixture.signal(drained)
        #expect(try await Fixture.idle(service, mailbox)["vector_snapshot_loaded"] as? Bool == false)
        #expect(mailbox.encoderEvents == 0)
    }

    @Test func disablingCodeRejectsBothDelayedMetadataAndVectorReaders() async throws {
        let root = try Fixture.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("index"), codeRoot = root.appendingPathComponent("code")
        let writer = try IndexStore(directory: directory)
        let code = try IndexStore(directory: directory, file: IndexStore.codeFile)
        try writer.insert(Candidate(path: root.appendingPathComponent("main.txt").path,
            kind: .doc, size: 10, mtime: 1, inode: 1, device: 1))
        try code.insert(Candidate(path: codeRoot.appendingPathComponent("source.py").path,
            kind: .doc, size: 10, mtime: 1, inode: 2, device: 1))
        try Fixture.seedVector(writer); try Fixture.seedVector(code)
        let mailbox = Mailbox()
        let service = try SearchService(index: directory, baseIndex: directory, roots: [root.path],
            skipped: [], types: [], codeRoots: [codeRoot.path], codeSkipped: [], idleSeconds: 300,
            fileExists: { _ in true }, onReply: { mailbox.receive($0) })
        let wordsEntered = DispatchSemaphore(value: 0), wordsRelease = DispatchSemaphore(value: 0)
        let vectorsEntered = DispatchSemaphore(value: 0), vectorsRelease = DispatchSemaphore(value: 0)
        defer { service.stop(); wordsRelease.signal(); vectorsRelease.signal() }
        service.lexical.submit(key: "held-code-metadata-owner") {
            wordsEntered.signal(); _ = wordsRelease.wait(timeout: .now() + 5)
        }
        try await Fixture.signal(wordsEntered)
        service.requestRefresh(vectors: true)
        try await Fixture.waitUntil { service.lexical.pendingCount > 0 }
        service.admit(SearchMessage(["op": "folders", "id": 90, "code_roots": []]))
        wordsRelease.signal()
        _ = try await mailbox.reply(90)
        _ = try await mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "ready" }
        let closedMetadata = try await Fixture.idle(service, mailbox)
        #expect(closedMetadata["code_reader_open"] as? Bool == false)
        #expect(closedMetadata["code_snapshot_loaded"] as? Bool == false)
        #expect(mailbox.values(event: "search_index", state: "words_ready").allSatisfy {
            $0["code_reader_open"] as? Bool == false
        })

        service.retrieval.submit(key: "held-code-vector-owner") {
            vectorsEntered.signal(); _ = vectorsRelease.wait(timeout: .now() + 5)
        }
        try await Fixture.signal(vectorsEntered)
        service.admit(SearchMessage(["op": "folders", "id": 91, "code_roots": [codeRoot.path]]))
        _ = try await mailbox.reply(91)
        try await Fixture.waitUntil { service.retrieval.pendingCount > 0 }
        service.admit(SearchMessage(["op": "folders", "id": 92, "code_roots": []]))
        _ = try await mailbox.reply(92)
        vectorsRelease.signal()
        _ = try await mailbox.take { $0["event"] as? String == "search_index" && $0["state"] as? String == "ready" }
        let closedVectors = try await Fixture.idle(service, mailbox)
        #expect(closedVectors["code_reader_open"] as? Bool == false)
        #expect(closedVectors["code_snapshot_loaded"] as? Bool == false)
        #expect(mailbox.values(event: "search_index", state: "ready").allSatisfy {
            ($0["code_vectors"] as? Int ?? -1) == 0
        })
        var retainedVectors: Int64 = 0
        try code.db.query("SELECT count(*) FROM segments WHERE vec IS NOT NULL") { retainedVectors = $0.int(0) }
        #expect(retainedVectors == 1)
        #expect(mailbox.encoderEvents == 0)
    }
}
