import Foundation
import Testing
@testable import DigUpKit
@testable import digup

/// Cross-stage acceptance: requires both streaming discovery and native-independent search metadata refresh.
@Suite(.serialized)
struct SearchDiscoveryIntegrationTests {
    typealias Fixture = SearchServiceFixture
    typealias Mailbox = Fixture.Mailbox
    typealias Counter = Fixture.Counter
    typealias Failure = Fixture.Failure

    @Test func blockedDiscoveryPublishesNamesKindsAndExactCollisionsWithoutAnEncoder() throws {
        let root = try Fixture.temporary()
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
        _ = try Fixture.idle(search, mailbox) // A pre-existing empty helper snapshot, before the scan.
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
                    _ = try Fixture.idle(search, mailbox)
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
                    #expect(try Fixture.idle(search, mailbox)["encoder"] as? String == "stopped")
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


}
