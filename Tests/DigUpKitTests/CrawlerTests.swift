import Foundation
import Testing
@testable import DigUpKit
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Suite struct CrawlerTests {
    @Test func localDocumentsAndVideoHeadersStillWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpCrawl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "A personal note".write(to: root.appendingPathComponent("note.txt"), atomically: false, encoding: .utf8)
        var bytes = [UInt8](repeating: 0, count: 188 * 4)
        for packet in 0..<4 { bytes[packet * 188] = 0x47 }
        try Data(bytes).write(to: root.appendingPathComponent("video.ts"))
        let report = Crawler.crawl([root], options: IndexOptions())
        #expect(report.candidates.count == 2)
        #expect(Set(report.candidates.map(\.kind)) == [.doc, .video])
    }

    #if os(Windows)
    @Test func offlineMediaIsExcludedBeforeHeaderInspection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpOffline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("offline.ts")
        try Data(repeating: 0, count: 752).write(to: file)
        let native = file.path.replacingOccurrences(of: "/", with: "\\")
        let updated = native.withCString(encodedAs: UTF16.self) { SetFileAttributesW($0, DWORD(FILE_ATTRIBUTE_OFFLINE)) }
        #expect(updated)
        let report = Crawler.crawl([root], options: IndexOptions())
        #expect(report.candidates.isEmpty)
        #expect(report.skipped["in the cloud, not downloaded"] == 1)
    }
    #else
    @Test func specialMediaCannotBlockTheScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("capture.ts").path
        #expect(mkfifo(path, 0o600) == 0)
        // Let an old/broken scanner return after two seconds so the regression fails instead of hanging CI.
        let release = DispatchWorkItem {
            let descriptor = open(path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try? handle.write(contentsOf: Data(repeating: 0, count: 752))
                try? handle.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: release)
        defer { release.cancel() }
        let start = Date()
        let report = Crawler.crawl([root], options: IndexOptions())
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(report.candidates.isEmpty)
        #expect(report.skipped["link or special file"] == 1)
    }
    #endif
}
