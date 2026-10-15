import Foundation
import Testing
@testable import DigUpKit

/// Broken metadata is a per-file problem; it must not terminate the indexing process.
@Suite struct PortableInputTests {
    #if !canImport(AppKit)
    @Test func malformedRTFUnicodeCannotTrapTheHelper() {
        for value in ["-9999999999", "9999999999", "-9223372036854775808", "9223372036854775807"] {
            let result = RTF.text("{\\rtf1 before \\u\(value)? after}")
            #expect(result.contains("before"))
            #expect(result.contains("after"))
        }
        #expect(RTF.text("{\\rtf1 \\u20320?\\u22909?}") == "你好")
    }
    #endif

    #if !canImport(ImageIO)
    @Test func oversizedHEIFBoxIsRejectedWithoutIntegerOverflow() throws {
        let ftyp: [UInt8] = [0, 0, 0, 12] + Array("ftypheic".utf8)
        let box: [UInt8] = [0, 0, 0, 1] + Array("meta".utf8)
            + [0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
        try rejectsMetadata(Data(ftyp + box))
    }

    @Test func emptyHEIFMetadataIsRejectedWithoutAnInvalidRange() throws {
        try rejectsMetadata(Data([0, 0, 0, 12] + Array("ftypheic".utf8) + [0, 0, 0, 8] + Array("meta".utf8)))
    }

    private func rejectsMetadata(_ data: Data) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("digup-malformed-\(UUID()).heic")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(EXIF.read(url) == nil)
    }
    #endif
}
