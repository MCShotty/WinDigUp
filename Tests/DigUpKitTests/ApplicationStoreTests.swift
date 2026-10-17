import Foundation
import Testing
@testable import DigUpKit

struct ApplicationStoreTests {
    private func document(_ id: String, text: String = "Photo editing", hash: Character = "a") -> ApplicationDocument {
        ApplicationDocument(id: "app:\(id)", name: id, text: text, hash: String(repeating: String(hash), count: 64))
    }
    private func vector(_ axis: Int) -> [Float] {
        var value = [Float](repeating: 0, count: 768); value[axis] = 1; return value
    }
    @Test func changesInvalidateOnlyTheirDocumentAndPruneRemovedApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ApplicationStore(directory: root)
        let a = document("photos"), b = document("browser")
        try store.synchronize([a, b], revision: "one")
        try store.prepare(fingerprint: "gpu")
        try store.save(vector(0), for: a, fingerprint: "gpu")
        try store.save(vector(1), for: b, fingerprint: "gpu")
        try store.synchronize([document("photos", text: "Retouch portraits", hash: "b"), b], revision: "two")
        #expect(try store.counts().embedded == 1)
        #expect(try store.pending()?.id == a.id)
        #expect(try store.search(vector(1), fingerprint: "gpu").first?.id == b.id)
        try store.synchronize([b], revision: "three")
        #expect(try store.counts().total == 1)
        try store.prepare(fingerprint: "npu-bundle-two")
        #expect(try store.counts().embedded == 0)
        #expect(try store.search(vector(1), fingerprint: "gpu").isEmpty == true)
    }
    @Test func rejectsInvalidVectorsAndStaleDocumentWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ApplicationStore(directory: root)
        let old = document("photos")
        try store.synchronize([document("photos", hash: "b")], revision: "new")
        try store.prepare(fingerprint: "gpu")
        try store.save(vector(0), for: old, fingerprint: "gpu")
        #expect(try store.counts().embedded == 0)
        #expect(throws: Database.Failure.self) { try store.save([Float](repeating: 0, count: 768), for: old, fingerprint: "gpu") }
        #expect(throws: Database.Failure.self) { try store.save(vector(0), for: old, fingerprint: "cpu") }
        #expect(throws: Database.Failure.self) { try store.synchronize([old, old], revision: "duplicates") }
    }
    @Test func fullRevisionAndProfileArePartOfFingerprint() {
        func info(_ revision: String) -> WorkerInfo {
            WorkerInfo(model: "model", revision: revision, runtime: "vectors2", dtype: "q8", dim: 768, textOnly: true, loadSeconds: nil)
        }
        #expect(ApplicationStore.fingerprint(info: info("1234567a"), backend: "vulkan") != ApplicationStore.fingerprint(info: info("1234567b"), backend: "vulkan"))
        #expect(ApplicationStore.fingerprint(info: info("1234567a"), backend: "vulkan") != ApplicationStore.fingerprint(info: info("1234567a"), backend: "openvino-npu"))
        #expect(ApplicationStore.fingerprint(info: info("1234567a"), backend: "vulkan", runtimeBuild: "b11461") != ApplicationStore.fingerprint(info: info("1234567a"), backend: "vulkan", runtimeBuild: "next-build"))
    }
    @Test func corruptApplicationCacheRecoversWithoutTouchingOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileIndex = root.appendingPathComponent("index.sqlite")
        try Data("file index sentinel".utf8).write(to: fileIndex)
        try Data("damaged disposable cache".utf8).write(to: root.appendingPathComponent(ApplicationStore.fileName))
        let store = try ApplicationStore.recovering(directory: root)
        #expect(try store.counts().total == 0)
        #expect(try String(contentsOf: fileIndex, encoding: .utf8) == "file index sentinel")
    }
    @Test func actualRuntimeFingerprintSurvivesSQLiteAndAcceptsVectors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ApplicationStore(directory: root)
        let info = WorkerInfo(model: "google/embeddinggemma-2", revision: "123456789abcdef", runtime: "llama.cpp-vectors2", dtype: "q8", dim: 768, textOnly: true, loadSeconds: nil)
        let fingerprint = ApplicationStore.fingerprint(info: info, backend: "amd-vulkan")
        let item = document("photos")
        try store.synchronize([item], revision: "one")
        try store.prepare(fingerprint: fingerprint)
        #expect(store.fingerprint == fingerprint)
        try store.save(vector(0), for: item, fingerprint: fingerprint)
        #expect(try store.counts().embedded == 1)
    }
    @Test func documentClaimsRejectOldCatalogAndCompetingOwners() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let first=try ApplicationStore(directory:root)
        let second=try ApplicationStore(directory:root)
        let item=document("editor")
        try first.synchronize([item],revision:"one")
        try first.prepare(fingerprint:"gpu")
        let claim=try #require(try first.claimPending(owner:"first",now:100))
        #expect(try second.claimPending(owner:"second",now:101)==nil)
        try first.synchronize([document("editor",text:"Changed purpose",hash:"b")],revision:"two")
        try first.save(vector(0),claim:claim)
        #expect(try first.counts().embedded==0)
        let current=try #require(try second.claimPending(owner:"second",now:102))
        try second.save(vector(0),claim:current)
        #expect(try first.counts().embedded==1)
        try first.prepare(fingerprint:"another-device")
        let expired=try #require(try first.claimPending(owner:"old",now:200))
        let replacement=try #require(try second.claimPending(owner:"new",now:381))
        try first.save(vector(0),claim:expired)
        #expect(try first.counts().embedded==0)
        try second.save(vector(0),claim:replacement)
        #expect(try first.counts().embedded==1)
    }

    @Test func presentationRevisionsRetainAnInFlightDocumentVector()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try ApplicationStore(directory:root)
        let item=document("editor")
        try store.synchronize([item],revision:"before-icon-change")
        try store.prepare(fingerprint:"gpu")
        let claim=try #require(try store.claimPending(owner:"worker"))
        try store.synchronize([item],revision:"after-icon-change")
        try store.save(vector(0),claim:claim)
        #expect(try store.counts().embedded==1)
        #expect(try store.pending()==nil)
    }

}
