import Foundation
import Testing
@testable import DigUpKit

@Suite struct MixedSearchRankingTests {
    @Test func bareCategoryWordsRetainNamesWithoutFileTypeBoosts() {
        for word in ["photos", "videos", "documents", "sound", "notes", "صور", "ছবি"] {
            #expect(Searcher.kindHints(word).isEmpty)
            #expect(!Searcher.terms(word).isEmpty)
        }
        #expect(Searcher.ftsQuery("photos") == "\"photos\"")
        #expect(Searcher.kindHints("change sound").isEmpty)
        #expect(Searcher.kindHints("sound settings").isEmpty)
        #expect(Searcher.kindHints("edit photos").isEmpty)
        #expect(Searcher.kindHints("default video player").isEmpty)
        #expect(Searcher.kindHints("photos of mountains") == [.image])
        #expect(Searcher.kindHints("sound of rain") == [.audio])
        #expect(Searcher.kindHints("zebra in a video") == [.video])
        #expect(Searcher.kindHints("صورة حمار وحشي") == [.image])
        #expect(Searcher.kindHints("জেব্রার ভিডিওতে") == [.video])
        #expect(Searcher.terms("photos of mountains") == ["mountains"])
    }

    @Test func categoryNamedFilesRemainSearchableWithExplicitFilters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(directory: directory)
        for (index, name) in ["Photos", "Videos", "Documents", "Sound"].enumerated() {
            try store.insert(Candidate(path: "/docs/\(name).txt", kind: .doc, size: 1, mtime: 1,
                                       inode: UInt64(index + 1), device: 1))
        }
        let searcher = try Searcher(store: store, loadVectors: false)
        for name in ["Photos", "Videos", "Documents", "Sound"] {
            #expect(try searcher.search(name, queryVector: nil).first?.path == "/docs/\(name).txt")
            #expect(try searcher.search(name, queryVector: nil, kinds: [.doc]).first?.path == "/docs/\(name).txt")
            #expect(try searcher.search(name, queryVector: nil, kinds: [.image]).isEmpty)
        }
    }
}
