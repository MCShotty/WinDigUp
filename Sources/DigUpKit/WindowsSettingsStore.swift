import Foundation

/// Separate documents and fingerprints; the same serialized encoder and query prompt are reused.
public enum WindowsSettingsStore {
    public static let fileName = "windows-settings.sqlite"
    public static let promptVersion = "windows-settings-document-v1-512"

    public static func recovering(directory: URL) throws -> ApplicationStore {
        try ApplicationStore.recovering(directory: directory, fileName: fileName, prefix: "setting:")
    }
}
