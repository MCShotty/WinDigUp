import Foundation
import DigUpKit

/// Metadata discovery never loads a model or queues work on the encoder.
func openVINOInventory() throws -> [String: Any] {
    let backend = try Acceleration.selected()
    do {
        let paths = try WorkerConfig.openVINOPaths()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("digup-openvino-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = folder.appendingPathComponent("devices.json")
        let process = Process()
        process.executableURL = paths.python
        process.arguments = ["-I", paths.script.deletingLastPathComponent().appendingPathComponent("setup_probe.py").path,
                             "--backend", backend.rawValue, "--output", report.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            EmbeddingWorker.interrupt(process)
            throw CLIError("OpenVINO device discovery timed out. Check the Intel driver and retry explicitly.")
        }
        guard process.terminationStatus == 0 else { throw CLIError("OpenVINO discovery failed; check Intel setup in Settings.") }
        let values = try report.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 262145) <= 262144 else { throw CLIError("OpenVINO discovery exceeded its output limit.") }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        guard let value else { throw CLIError("Invalid OpenVINO discovery response.") }
        return value
    } catch {
        return ["schemaVersion": 1, "probeOnly": true, "devices": [], "runtimeReady": false,
                "backends": [["backend": backend.rawValue, "state": "unavailable", "message": "\(error)"]]]
    }
}
