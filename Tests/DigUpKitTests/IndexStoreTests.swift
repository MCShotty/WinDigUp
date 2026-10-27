#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
@testable import DigUpKit
#if os(Windows)
import WinSDK
#endif

@Suite struct IndexStoreTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func file(_ path: String, inode: UInt64) -> Candidate {
        Candidate(path: path, kind: .image, size: 10, mtime: 1, inode: inode, device: 1)
    }

    @Test func pruneKeepsOnlyChosenFolders() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/a/sub/y.png", inode: 2))
        try store.insert(file("/ab/z.png", inode: 3))   // a sibling whose name starts like "/a", not inside it
        try store.insert(file("/b/w.png", inode: 4))
        #expect(try store.prune(keepingUnder: ["/a"]) == 2)
        #expect(try store.files(under: ["/a"]).count == 2)
        #expect(try store.files(under: ["/ab", "/b"]).isEmpty)
        var keywordRows = 0
        try store.db.query("SELECT COUNT(*) FROM fts") { keywordRows = Int($0.int(0)) }
        #expect(keywordRows == 2)   // the pruned files' names left keyword search too
        #expect(try store.prune(keepingUnder: []) == 2)
    }

    @Test(arguments:[false,true])
    func unicodeHoldPrefixesKeepEveryLiteralSpellingWhenCollapsed(collapse:Bool) throws {
        let store=try IndexStore(directory:folder)
        let composed="/fixture/Caf\u{e9}",decomposed="/fixture/Cafe\u{301}",ready="/fixture/ready"
        #expect(composed==decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        #expect(IndexStore.uniqueLiteralPaths([composed,decomposed,composed]).count==2)
        store.setLiteralScope([composed,decomposed,ready])
        for (index,path) in [composed,decomposed].enumerated() {
            _=try store.insert(file(path+"/held/pending.png",inode:UInt64(index*2+1)))
            let partial=try store.insert(file(path+"/held/long.png",inode:UInt64(index*2+2)))
            try store.finish(partial,state:"partial",info:["read_to":"1","read_end":"10"])
        }
        _=try store.insert(file(ready+"/available.png",inode:9))
        let holds=collapse
            ? (0..<65).flatMap {[composed+"/held/\($0)",decomposed+"/held/\($0)"]}
            : [composed+"/held",decomposed+"/held"]
        store.pendingExcludedPaths=holds
        #expect(try store.pendingCount()==1)
        #expect(try store.pending(limit:nil).map(\.path)==[ready+"/available.png"])
        #expect(try store.runnableUnfinishedCount()==0)
        #expect(try store.unfinishedCount().files==2)
        let inventory=try store.counts()
        #expect(inventory.byKindAndState["image"]?["pending"]==3)
        if collapse {
            #expect(store.pendingExcludedPaths.count==2)
            #expect(Set(store.pendingExcludedPaths.map {Data($0.utf8)})==Set([Data(composed.utf8),Data(decomposed.utf8)]))
        }
        store.pendingExcludedPaths=[]
        #expect(try store.pendingCount()==3)
        #expect(try store.runnableUnfinishedCount()==2)
    }

    @Test func scopeLimitsWhatIsWaiting() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/drive/y.png", inode: 2))   // on a drive that's unplugged
        store.scope = ["/a"]
        #expect(try store.pendingCount() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/x.png"])
        #expect(try store.counts().byKindAndState["image"]?["pending"] == 1)
        store.scope = []
        #expect(try store.pendingCount() == 0)
        store.scope = nil
        #expect(try store.pendingCount() == 2)
    }

    @Test func aFileTheHelperStoppedOnIsNotReadAgain() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/stuck.pdf", inode: 1))
        let book = try store.insert(file("/a/book.pdf", inode: 2))
        try store.finish(book, state: "partial", info: ["read_to": "30", "read_end": "463"])
        #expect(try store.markStopped("/a/stuck.pdf", why: "took more than 15 minutes to read"))
        #expect(try store.markStopped("/a/book.pdf", why: "took more than 15 minutes to read"))
        #expect(try !store.markStopped("/a/gone.pdf", why: "took more than 15 minutes to read"))
        #expect(try store.pendingCount() == 0)
        #expect(try store.unfinishedCount().files == 0)   // the book keeps its first pages and isn't finished again
        let states = Dictionary(uniqueKeysWithValues: try store.files(under: ["/a"]).map { ($0.path, $0.state) })
        #expect(states == ["/a/stuck.pdf": "failed", "/a/book.pdf": "done"])
    }

    #if canImport(AppKit)
    @Test func picturesThatCouldntBeReadAreReadOnceMore() throws {
        // An SVG skipped by an older DigUp as "small image 0×0" (ImageIO couldn't open it): AppKit draws it now.
        let store = try IndexStore(directory: folder)
        let svg = try store.insert(file("/a/chart.svg", inode: 1))
        try store.finish(svg, state: "skipped", detail: "small image 0×0")
        let icon = try store.insert(file("/a/icon.png", inode: 2))
        try store.finish(icon, state: "skipped", detail: "small image 160×160")   // small, and rightly skipped
        #expect(try store.readAgainOnce() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/chart.svg"])
        #expect(try store.readAgainOnce() == 0)
    }
    #endif

    @Test func modelFileHashesStreamInPieces() throws {
        let small = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: small)
        #expect(try ModelFiles.sha256(of: small) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Bigger than one 8 MB piece.
        let bytes = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let big = folder.appendingPathComponent("big")
        try bytes.write(to: big)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try ModelFiles.sha256(of: big) == expected)
    }

    @Test func missingModelFilesInDownloadOrder() throws {
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.text, ModelFiles.media])
        FileManager.default.createFile(atPath: folder.appendingPathComponent(ModelFiles.text.name).path, contents: nil)
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.media])
        #expect(ModelFiles.totalBytes == 864_676_480)
    }

    @Test func modelFilesComeFromTheHuggingFaceCacheWhenThere() throws {
        // As `hf download` leaves them: snapshots/<revision>/<name> → a blob. Sparse, so no disk is used.
        let hub = folder.appendingPathComponent("hub")
        let snapshot = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/snapshots/\(ModelFiles.revision)")
        let blobs = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("2188ac1d")
        FileManager.default.createFile(atPath: blob.path, contents: nil)
        try FileHandle(forWritingTo: blob).truncate(atOffset: UInt64(ModelFiles.text.bytes))
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(ModelFiles.text.name),
                                                   withDestinationURL: blob)
        setEnvironment("HF_HUB_CACHE", hub.path)
        defer { setEnvironment("HF_HUB_CACHE", nil) }
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text)?.lastPathComponent == "2188ac1d")
        #expect(ModelFiles.cachedCopy(of: ModelFiles.media) == nil)   // not there
        try FileHandle(forWritingTo: blob).truncate(atOffset: 10)
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text) == nil)    // not whole
    }

    @Test func syncKeepsTheRowsOfAFolderThatWentAway() throws {
        // The real path (/private/var/…), as the crawler reports it; resolvingSymlinksInPath() would drop "/private".
        let base = URL(fileURLWithPath: FolderSelection.realPath(folder.path))
        let drive = base.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("notes from the trip".utf8).write(to: drive.appendingPathComponent("notes.txt"))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        #expect(try indexer.sync([drive]).added == 1)
        try FileManager.default.moveItem(at: drive, to: base.appendingPathComponent("ejected"))
        #expect(try indexer.sync([drive]).removed == 0)   // an ejected drive is not "everything deleted"
        #expect(try store.files(under: [drive.path]).count == 1)
    }

    #if !os(Windows)
    @Test func incompleteScanPreservesUnreadableSubtreesButRemovesRealDeletions() throws {
        // Run as a normal user: root can read a directory even after chmod(000).
        guard geteuid() != 0 else { return }
        let root = URL(fileURLWithPath: FolderSelection.realPath(folder.path)).appendingPathComponent("files")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let kept = locked.appendingPathComponent("kept.txt")
        let removed = root.appendingPathComponent("removed.txt")
        try Data("keep this indexed document".utf8).write(to: kept)
        try Data("this document will be deleted".utf8).write(to: removed)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        #expect(try indexer.sync([root]).added == 2)
        let keptID = try #require(store.files(under: [locked.path]).first?.id)
        try store.finish(keptID, state: "done")
        try FileManager.default.removeItem(at: removed)
        #expect(chmod(locked.path, 0) == 0)
        defer { _ = chmod(locked.path, 0o755) }
        let scan = try indexer.sync([root])
        #expect(scan.removed == 1)
        let remaining = try store.files(under: [root.path])
        #expect(remaining.map(\.id) == [keptID])
        #expect(remaining.first?.state == "done")
        #expect(chmod(locked.path, 0o755) == 0)
        #expect(try indexer.sync([root]).unchanged == 1)
    }
    #endif

    @Test func renameToAnotherKindMustReindexInsteadOfReusingOldVectors() throws {
        let root = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before = root.appendingPathComponent("photo.jpg")
        let after = root.appendingPathComponent("notes.txt")
        try Data("same bytes, different interpretation".utf8).write(to: before)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        #expect(try indexer.sync([root]).added == 1)
        let oldID = try #require(store.files(under: [root.path]).first?.id)
        try store.finish(oldID, state: "done")
        try FileManager.default.moveItem(at: before, to: after)
        let scan = try indexer.sync([root])
        let changed = try #require(store.files(under: [root.path]).first)
        #expect(scan.moved == 0)
        #expect(changed.kind == .doc)
        #expect(changed.state == "pending")
    }

    @Test func syncFindsTheRowsOfAFolderSpelledAnotherWay() throws {
        // The walk stores paths as the disk spells them, and on a Mac these folders are chosen spelled otherwise twice
        // over: under /var where the disk says /private/var (the temporary folder), and with a name the disk keeps
        // precomposed that `standardizedFileURL` decomposes (Google Drive's "내 드라이브", "Café"). Looking their rows up
        // by that spelling found none, so the second sync took every file for new: "UNIQUE constraint failed".
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(),
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        var chosen: [URL] = []
        for name in ["내 드라이브", "Café"] {
            let onDisk = folder.path + "/" + name.precomposedStringWithCanonicalMapping
            #if os(Windows)
            try FileManager.default.createDirectory(atPath: onDisk, withIntermediateDirectories: false)
            #else
            #expect(mkdir(onDisk, 0o755) == 0)   // FileManager would decompose the name
            #endif
            try Data("notes from the trip".utf8).write(to: URL(fileURLWithPath: onDisk + "/notes.txt"))
            chosen.append(URL(fileURLWithPath: onDisk).standardizedFileURL)
        }
        #expect(try indexer.sync(chosen).added == 2)
        let again = try indexer.sync(chosen)
        #expect(again.added == 0 && again.unchanged == 2)
        #expect(try store.files(under: chosen.map(\.path)).count == 2)
        store.scope = chosen.map(\.path)
        #expect(try store.pendingCount() == 2)
        #expect(try store.prune(keepingUnder: chosen.map(\.path)) == 0)
    }
}

/// Sets an environment variable of this process, or removes it (nil).
private func setEnvironment(_ name: String, _ value: String?) {
    #if os(Windows)
    _ = name.withCString(encodedAs: UTF16.self) { name in
        guard let value else { return SetEnvironmentVariableW(name, nil) }
        return value.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(name, $0) }
    }
    #else
    if let value { setenv(name, value, 1) } else { unsetenv(name) }
    #endif
}
