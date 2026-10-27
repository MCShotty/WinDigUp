import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

@testable import DigUpKit
#if canImport(CSearchMath)
import CSearchMath
#endif

@Suite struct SearchReadersTests {
    #if !canImport(Accelerate)
    @Test func portableHalfConversionPreservesEveryFinitePatternAndBounds() {
        let input = [Float16(42)] + (0...65_535).map { Float16(bitPattern: UInt16($0)) }
            + [Float16(-2), Float16.infinity, Float16(0.5)]
        let count = input.count - 1
        var output = [Float](repeating: 123_456, count: count + 6)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                Vectors.floats(fromHalf: source.baseAddress! + 1, count: count, to: destination.baseAddress! + 3)
            }
        }
        var mismatch: Int?
        for index in 0..<count {
            let expected = Float(input[index + 1]), actual = output[index + 3]
            if expected.isNaN ? !actual.isNaN : expected.bitPattern != actual.bitPattern { mismatch = index; break }
        }
        #expect(mismatch == nil)
        #expect(output.prefix(3).allSatisfy { $0 == 123_456 })
        #expect(output.suffix(3).allSatisfy { $0 == 123_456 })
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                (source.baseAddress! + 1).withMemoryRebound(to: UInt16.self, capacity: count) { halves in
                    digup_search_half_to_float_portable(halves, destination.baseAddress! + 3, count)
                }
            }
        }
        mismatch = nil
        for index in 0..<count {
            let expected = Float(input[index + 1]), actual = output[index + 3]
            if expected.isNaN ? !actual.isNaN : expected.bitPattern != actual.bitPattern { mismatch = index; break }
        }
        #expect(mismatch == nil)
        #expect(output.prefix(3).allSatisfy { $0 == 123_456 })
        #expect(output.suffix(3).allSatisfy { $0 == 123_456 })
    }
    #endif
    @Test func exactNamesCoverFilesOutsideTopHitsAndInvalidateAfterWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try IndexStore(directory: root)
        try writer.insert(Candidate(path: "/files/Café.txt", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
        let reader = try IndexStore(directory: root, readOnly: true)
        let search = try Searcher(store: reader, loadVectors: false, loadNames: true)
        #expect(try search.exactNamePaths("CAFE") == ["/files/Café.txt"])
        #expect(try search.exactNamePaths("absent") == [])
        try writer.insert(Candidate(path: "/files/Firefox.txt", kind: .doc, size: 1, mtime: 1, inode: 2, device: 1))
        #expect(try search.exactNamePaths("Firefox") == nil)
    }
    final class ConcurrentInsert {
        let writer: IndexStore
        let candidate: Candidate
        var inserted = false
        var error: (any Error)?
        init(writer: IndexStore, candidate: Candidate) { self.writer = writer; self.candidate = candidate }
        func beforeBegin() {
            guard !inserted else { return }
            inserted = true
            do { _ = try writer.insert(candidate) } catch { self.error = error }
        }
    }

    @Test func exactNamesAndKindsShareOneRevisionDuringConcurrentDiscovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try IndexStore(directory: root)
        try writer.insert(Candidate(path: "/files/existing.txt", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
        let reader = try IndexStore(directory: root, readOnly: true)
        let candidate = Candidate(path: "/files/snapshotimage.png", kind: .image, size: 1, mtime: 1, inode: 2, device: 1)
        let insertion = ConcurrentInsert(writer: writer, candidate: candidate)
        let code = sqlite3_trace_v2(reader.db.handle, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)),
                  String(cString: sql).uppercased() == "BEGIN" else { return 0 }
            // Another connection commits exactly at the boundary. Before the fix, the kind map had
            // already been read; the name snapshot then observed the newer file and disagreed with it.
            Unmanaged<ConcurrentInsert>.fromOpaque(context).takeUnretainedValue().beforeBegin()
            return 0
        }, Unmanaged.passUnretained(insertion).toOpaque())
        #expect(code == SQLITE_OK)
        defer {
            sqlite3_trace_v2(reader.db.handle, 0, nil, nil)
            withExtendedLifetime(insertion) {}
        }
        let search = try Searcher(store: reader, loadVectors: false, loadNames: true)
        if let error = insertion.error { throw error }
        #expect(insertion.inserted)
        #expect(try search.exactNamePaths("snapshotimage") == [candidate.path])
        #expect(try search.search("snapshotimage", queryVector: nil, kinds: [.image]).map(\.path) == [candidate.path])
        #expect(try search.search("snapshotimage", queryVector: nil, kinds: [.doc]).isEmpty)
        // The constructor releases its read transaction, so later discovery invalidates exact names.
        try writer.insert(Candidate(path: "/files/later.txt", kind: .doc, size: 1, mtime: 1, inode: 3, device: 1))
        #expect(try search.exactNamePaths("later") == nil)
    }

    @Test func readersPinOneRevisionWithoutBlockingTheWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try IndexStore(directory: root)
        try writer.insert(Candidate(path: "/docs/alpha.txt", kind: .doc, size: 1, mtime: 1, inode: 1, device: 1))
        let reader = try IndexStore(directory: root, readOnly: true)
        try reader.db.execute("BEGIN")
        #expect(try reader.files(under: ["/docs"]).count == 1)
        try writer.insert(Candidate(path: "/docs/beta.txt", kind: .doc, size: 1, mtime: 1, inode: 2, device: 1))
        #expect(try reader.files(under: ["/docs"]).count == 1)
        #expect(throws: Database.Failure.self) { try reader.db.execute("DELETE FROM files") }
        try reader.db.execute("ROLLBACK")
        #expect(try reader.files(under: ["/docs"]).count == 2)
    }
    @Test func missingReaderDoesNotCreateAnIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: Database.Failure.self) { _ = try IndexStore(directory: root, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func facetsAndFilteredResultsShareTheSameSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(directory: root)
        for (index, kind) in [FileKind.doc, .image, .pdf].enumerated() {
            try store.insert(
                Candidate(
                    path: "/files/receipt-\(index).txt", kind: kind, size: 10, mtime: 1, inode: UInt64(index + 1),
                    device: 1))
        }
        let search = try Searcher(store: store, loadVectors: false)
        let expected = try search.search("receipt", queryVector: nil, kinds: [.doc])
        let combined = try search.search("receipt", queryVector: nil, kinds: [.doc], includeFacets: true)
        #expect(combined.map(\.path) == expected.map(\.path))
        #expect(search.facetCounts["doc"] == 1)
        #expect(search.facetCounts["image"] == 1)
        #expect(search.facetCounts["pdf"] == 1)
        #expect(search.timings["metadata"] != nil)
    }
}
