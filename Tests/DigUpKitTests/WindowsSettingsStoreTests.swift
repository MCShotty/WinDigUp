import Foundation
import Testing
@testable import DigUpKit

struct WindowsSettingsStoreTests {
    @Test func namespacesAndVectorsRemainIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = try ApplicationStore(directory: root)
        let settings = try WindowsSettingsStore.recovering(directory: root)
        let app = ApplicationDocument(id: "app:editor", name: "Editor", text: "Edit photos", hash: String(repeating: "a", count: 64))
        let page = ApplicationDocument(id: "setting:display", name: "Display", text: "Screen brightness", hash: String(repeating: "b", count: 64))
        try apps.synchronize([app], revision: "apps")
        try settings.synchronize([page], revision: "settings")
        var vector = [Float](repeating: 0, count: 768); vector[0] = 1
        try apps.prepare(fingerprint: "apps-gpu")
        try settings.prepare(fingerprint: "settings-gpu")
        try apps.save(vector, for: app, fingerprint: "apps-gpu")
        try settings.save(vector, for: page, fingerprint: "settings-gpu")
        #expect(try apps.counts().total == 1)
        #expect(try settings.counts().total == 1)
        #expect(try apps.search(vector, fingerprint: "apps-gpu").first?.id == app.id)
        #expect(try settings.search(vector, fingerprint: "settings-gpu").first?.id == page.id)
        #expect(throws: Database.Failure.self) { try apps.synchronize([page], revision: "wrong") }
        #expect(throws: Database.Failure.self) { try settings.synchronize([app], revision: "wrong") }
        #expect(try settings.search(vector, fingerprint: "apps-gpu").isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("applications.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("windows-settings.sqlite").path))
    }
    @Test func settingsUseTheirOwnDocumentFingerprint() {
        let info = WorkerInfo(model: "model", revision: "full-revision", runtime: "runtime", dtype: "q8", dim: 768, textOnly: true, loadSeconds: nil)
        let app = ApplicationStore.fingerprint(info: info, backend: "amd-vulkan")
        let settings = ApplicationStore.fingerprint(info: info, backend: "amd-vulkan", documentPromptVersion: WindowsSettingsStore.promptVersion)
        #expect(app != settings)
    }
    @Test func corruptSettingsCacheDoesNotTouchApplicationsOrFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("applications.sqlite"), file = root.appendingPathComponent("index.sqlite")
        try Data("application sentinel".utf8).write(to: app)
        try Data("file sentinel".utf8).write(to: file)
        try Data("broken settings cache".utf8).write(to: root.appendingPathComponent(WindowsSettingsStore.fileName))
        let recovered = try WindowsSettingsStore.recovering(directory: root)
        #expect(try recovered.counts().total == 0)
        #expect(try String(contentsOf: app, encoding: .utf8) == "application sentinel")
        #expect(try String(contentsOf: file, encoding: .utf8) == "file sentinel")
    }
}
