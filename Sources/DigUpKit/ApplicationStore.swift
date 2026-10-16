import Foundation

/// Application identities are not filesystem paths. This cache never participates in the file crawler/schema.
public struct ApplicationDocument: Codable, Sendable {
    public let id: String
    public let name: String
    public let text: String
    public let hash: String
    public init(id: String, name: String, text: String, hash: String) {
        self.id = id; self.name = name; self.text = text; self.hash = hash
    }
}

public final class ApplicationStore {
    public static let fileName = "applications.sqlite"
    public static let promptVersion = "applications-document-v1-512"
    // Conservative initial gates. Real-model relevance calibration is recorded separately from unit tests.
    public static let rankingVersion = 1
    public static let minimumCosine: Float = 0.60
    public static let distanceFromBest: Float = 0.08
    private let db: Database

    public static func recovering(directory: URL) throws -> ApplicationStore {
        do { return try ApplicationStore(directory: directory) }
        catch {
            let message = String(describing: error).lowercased()
            guard message.contains("not a database") || message.contains("malformed") else { throw error }
            // This file is disposable and owned only by the query helper. User annotations live in Settings.
            for suffix in ["", "-wal", "-shm"] {
                let file = directory.appendingPathComponent(fileName + suffix)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            return try ApplicationStore(directory: directory)
        }
    }

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try Database(path: directory.appendingPathComponent(Self.fileName).path)
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version <= 1 else { throw Database.Failure(message: "Application cache was made by a newer DigUp") }
        if version == 0 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS applications(
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, text TEXT NOT NULL, hash TEXT NOT NULL,
                        revision TEXT NOT NULL, vector BLOB
                    );
                    PRAGMA user_version = 1;
                    """)
            }
        }
    }

    public var revision: String { (try? meta("revision")) ?? "" }
    public var fingerprint: String? { try? meta("fingerprint") }
    private func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM app_meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
        return value
    }
    private func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO app_meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   [.text(key), .text(value)])
    }

    /// Includes the full revision, not the abbreviated display label, and the actual NPU bundle runtime fingerprint.
    public static func fingerprint(info: WorkerInfo, backend: String, runtimeBuild: String = "") -> String {
        // SQLite's text binder uses NUL termination. Encode components before joining, keeping the identity lossless.
        var components = [info.model, info.revision, info.runtime, runtimeBuild, info.dtype, String(info.dim), backend, promptVersion]
        if backend == "nvidia-cuda" { components += [info.precisionProfile ?? "", info.buildIdentity ?? "", info.vectorSource] }
        return components.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    public func synchronize(_ documents: [ApplicationDocument], revision: String) throws {
        guard documents.count <= 20_000, revision.count <= 128, !revision.contains("\0"),
              Set(documents.map(\.id)).count == documents.count,
              documents.allSatisfy({ $0.id.hasPrefix("app:") && $0.id.count <= 128 && $0.hash.count == 64
                  && $0.name.count <= 4096 && $0.text.count <= 16_384
                  && !$0.id.contains("\0") && !$0.name.contains("\0") && !$0.text.contains("\0") && !$0.hash.contains("\0") }) else {
            throw Database.Failure(message: "Invalid application catalog snapshot")
        }
        try db.transaction {
            for document in documents {
                try db.run("""
                    INSERT INTO applications(id,name,text,hash,revision) VALUES(?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name,text=excluded.text,hash=excluded.hash,
                        revision=excluded.revision,vector=CASE WHEN applications.hash=excluded.hash THEN applications.vector ELSE NULL END
                    """, [.text(document.id), .text(document.name), .text(document.text), .text(document.hash), .text(revision)])
            }
            try db.run("DELETE FROM applications WHERE revision != ?", [.text(revision)])
            try setMeta("revision", revision)
        }
    }

    public func prepare(fingerprint: String) throws {
        guard !fingerprint.contains("\0") else { throw Database.Failure(message: "Invalid application fingerprint") }
        if self.fingerprint != fingerprint {
            try db.transaction {
                try db.execute("UPDATE applications SET vector=NULL")
                try setMeta("fingerprint", fingerprint)
            }
        }
    }

    public func pending() throws -> ApplicationDocument? {
        var result: ApplicationDocument?
        try db.query("SELECT id,name,text,hash FROM applications WHERE vector IS NULL ORDER BY id LIMIT 1") { row in
            result = ApplicationDocument(id: row.text(0)!, name: row.text(1)!, text: row.text(2)!, hash: row.text(3)!)
        }
        return result
    }

    public func save(_ vector: [Float], for document: ApplicationDocument, fingerprint: String) throws {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard vector.count == 768, vector.allSatisfy({ $0.isFinite }), abs(norm - 1) < 0.005,
              self.fingerprint == fingerprint else {
            throw Database.Failure(message: "Invalid or incompatible application embedding; no host normalization is allowed")
        }
        // A small catalog uses full float32 storage. Serialization is not model arithmetic.
        let words = vector.map { $0.bitPattern.littleEndian }
        let data = words.withUnsafeBytes { Data($0) }
        try db.run("UPDATE applications SET vector=? WHERE id=? AND hash=?",
                   [.blob(data), .text(document.id), .text(document.hash)])
    }

    public func counts() throws -> (total: Int, embedded: Int) {
        var result = (total: 0, embedded: 0)
        try db.query("SELECT count(*),count(vector) FROM applications") { result = (Int($0.int(0)), Int($0.int(1))) }
        return result
    }

    public func search(_ query: [Float], fingerprint: String, limit: Int = 20_000,
                       minimumCosine: Float = minimumCosine) throws -> [(id: String, cosine: Float)] {
        guard query.count == 768, query.allSatisfy({ $0.isFinite }), self.fingerprint == fingerprint else { return [] }
        var scores: [(id: String, cosine: Float)] = []
        try db.query("SELECT id,vector FROM applications WHERE vector IS NOT NULL") { row in
            guard let data = row.blob(1), data.count == 768 * 4 else { return }
            var score: Float = 0
            data.withUnsafeBytes { bytes in
                for i in 0..<768 {
                    let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                    score += query[i] * value
                }
            }
            if score.isFinite && score >= minimumCosine { scores.append((row.text(0)!, score)) }
        }
        scores.sort { $0.cosine == $1.cosine ? $0.id < $1.id : $0.cosine > $1.cosine }
        guard let best = scores.first?.cosine else { return [] }
        return Array(scores.filter { $0.cosine >= best - Self.distanceFromBest }.prefix(min(max(limit, 1), 20_000)))
    }
}
