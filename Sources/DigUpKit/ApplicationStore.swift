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
    private let documentPrefix: String

    public static func recovering(directory: URL, fileName: String = ApplicationStore.fileName, prefix: String = "app:") throws -> ApplicationStore {
        do { return try ApplicationStore(directory: directory, fileName: fileName, prefix: prefix) }
        catch {
            let message = String(describing: error).lowercased()
            guard message.contains("not a database") || message.contains("malformed") else { throw error }
            // This file is disposable and owned only by the query helper. User annotations live in Settings.
            for suffix in ["", "-wal", "-shm"] {
                let file = directory.appendingPathComponent(fileName + suffix)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            return try ApplicationStore(directory: directory, fileName: fileName, prefix: prefix)
        }
    }

    public init(directory: URL, readOnly: Bool = false, fileName: String = ApplicationStore.fileName, prefix: String = "app:") throws {
        guard (fileName == ApplicationStore.fileName && prefix == "app:") || (fileName == "windows-settings.sqlite" && prefix == "setting:") else {
            throw Database.Failure(message: "Invalid launcher document namespace")
        }
        documentPrefix = prefix
        if !readOnly { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        db = try Database(path: directory.appendingPathComponent(fileName).path, readOnly: readOnly)
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version <= 2 else { throw Database.Failure(message: "Application cache was made by a newer DigUp") }
        if readOnly {
            guard version == 1 || version == 2 else { throw Database.Failure(message: "Application cache is not prepared") }
            return
        }
        if version == 0 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS applications(
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, text TEXT NOT NULL, hash TEXT NOT NULL,
                        revision TEXT NOT NULL, vector BLOB, lease_owner TEXT, lease_until INTEGER NOT NULL DEFAULT 0
                    );
                    PRAGMA user_version = 2;
                    """)
            }
        }
        if version == 1 {
            try db.transaction {
                try db.execute("ALTER TABLE applications ADD COLUMN lease_owner TEXT; ALTER TABLE applications ADD COLUMN lease_until INTEGER NOT NULL DEFAULT 0; PRAGMA user_version=2;")
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
    public static func fingerprint(info: WorkerInfo, backend: String, runtimeBuild: String = "", documentPromptVersion: String = ApplicationStore.promptVersion) -> String {
        // SQLite's text binder uses NUL termination. Encode components before joining, keeping the identity lossless.
        var components = [info.model, info.revision, info.runtime, runtimeBuild, info.dtype, String(info.dim), backend, documentPromptVersion]
        if backend == "nvidia-cuda" { components += [info.precisionProfile ?? "", info.buildIdentity ?? "", info.vectorSource] }
        return components.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    public func synchronize(_ documents: [ApplicationDocument], revision: String) throws {
        guard documents.count <= 20_000, revision.count <= 128, !revision.contains("\0"),
              Set(documents.map(\.id)).count == documents.count,
              documents.allSatisfy({ $0.id.hasPrefix(documentPrefix) && $0.id.count <= 128 && $0.hash.count == 64
                  && $0.name.count <= 4096 && $0.text.count <= 16_384
                  && !$0.id.contains("\0") && !$0.name.contains("\0") && !$0.text.contains("\0") && !$0.hash.contains("\0") }) else {
            throw Database.Failure(message: "Invalid application catalog snapshot")
        }
        try db.transaction {
            for document in documents {
                try db.run("""
                    INSERT INTO applications(id,name,text,hash,revision) VALUES(?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name,text=excluded.text,hash=excluded.hash,
                        revision=excluded.revision,vector=CASE WHEN applications.hash=excluded.hash THEN applications.vector ELSE NULL END,
                        lease_owner=CASE WHEN applications.hash=excluded.hash THEN applications.lease_owner ELSE NULL END,
                        lease_until=CASE WHEN applications.hash=excluded.hash THEN applications.lease_until ELSE 0 END
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
                try db.execute("UPDATE applications SET vector=NULL,lease_owner=NULL,lease_until=0")
                try setMeta("fingerprint", fingerprint)
            }
        }
    }

    public struct Claim: Sendable {
        public let document: ApplicationDocument
        public let revision: String
        public let owner: String
        public let fingerprint: String
    }
    public func claimPending(owner: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Claim? {
        guard !owner.isEmpty,owner.count<=128 else{throw Database.Failure(message:"Invalid application preparation owner")}
        return try db.transaction {
            var document:ApplicationDocument?
            try db.query("SELECT id,name,text,hash FROM applications WHERE vector IS NULL AND (lease_until<=? OR lease_until>?) ORDER BY id LIMIT 1",[.int(now),.int(now+180)]){row in
                document=ApplicationDocument(id:row.text(0)!,name:row.text(1)!,text:row.text(2)!,hash:row.text(3)!)
            }
            guard let document,let fingerprint=self.fingerprint else{return nil}
            try db.run("UPDATE applications SET lease_owner=?,lease_until=? WHERE id=? AND hash=?",
                [.text(owner),.int(now+180),.text(document.id),.text(document.hash)])
            return Claim(document:document,revision:revision,owner:owner,fingerprint:fingerprint)
        }
    }
    public func release(_ claim: Claim) throws {
        try db.run("UPDATE applications SET lease_owner=NULL,lease_until=0 WHERE id=? AND lease_owner=?",
            [.text(claim.document.id),.text(claim.owner)])
    }
    public func save(_ vector:[Float],claim:Claim)throws {
        try db.transaction {
            guard fingerprint==claim.fingerprint else{return}
            var owner:String?
            try db.query("SELECT lease_owner FROM applications WHERE id=? AND hash=?",
                [.text(claim.document.id),.text(claim.document.hash)]){owner=$0.text(0)}
            guard owner==claim.owner else{return}
            try save(vector,for:claim.document,fingerprint:claim.fingerprint)
            try release(claim)
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
