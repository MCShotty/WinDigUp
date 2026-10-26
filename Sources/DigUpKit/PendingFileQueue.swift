import Foundation

/// A disposable, connection-owned snapshot. Durable file states change only at publication.
final class PendingFileQueue {
    struct Entry {
        let file: FileRecord
        let priority: Int
        let ordinal: Int64
    }
    private(set) var total = 0
    private let store: IndexStore
    private let table: String
    private let members: String
    private let pageSize: Int
    private let state: String
    private let scopeSQL: String
    private let scopeValues: [SQLValue]
    private var after: Int64 = 0
    private var lastOrdinal: Int64 = 0
    private var buffer: [Entry] = []
    private var offset = 0
    private var exhausted = false
    private var closed = false
    private var preferredPath: String?
    private(set) var buildMs = 0.0
    private(set) var fetchMs = 0.0
    private(set) var pages = 0
    private(set) var rows = 0
    private(set) var peakBufferedRecords = 0

    init(store: IndexStore, priorityIDs: Set<Int64>, includePending: Bool, limit: Int?,
         state: String = "pending", scopeSQL: String, scopeValues: [SQLValue], pageSize: Int = 128) throws {
        self.store = store
        self.state = state
        self.scopeSQL = scopeSQL
        self.scopeValues = scopeValues
        self.pageSize = min(256, max(8, pageSize))
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        table = "digup_queue_" + suffix
        members = "digup_priority_" + suffix
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try store.db.execute("CREATE TEMP TABLE \(members)(file INTEGER PRIMARY KEY); CREATE TEMP TABLE \(table)(ord INTEGER PRIMARY KEY, file INTEGER UNIQUE, priority INTEGER NOT NULL);")
            try store.db.transaction {
                for id in priorityIDs {
                    try store.db.run("INSERT INTO \(members)(file) VALUES(?)", [.int(id)])
                }
                let membership = "EXISTS(SELECT 1 FROM \(members) p WHERE p.file=files.id)"
                let source = includePending ? "files" : "\(members) selected CROSS JOIN files ON files.id=selected.file"
                try store.db.run("""
                    INSERT INTO \(table)(file,priority)
                    SELECT id,CASE WHEN \(membership) THEN 0 ELSE 1 END
                    FROM \(source) WHERE state=?\(scopeSQL)
                    ORDER BY 2,\(FileKind.indexingOrderSQL),mtime DESC,id ASC LIMIT ?
                    """, [.text(state)] + scopeValues + [.int(Int64(max(-1, limit ?? -1)))])
            }
            var count = 0
            try store.db.query("SELECT COUNT(*) FROM \(table)") { count = Int($0.int(0)) }
            total = count
            lastOrdinal=Int64(count)
            buildMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        } catch {
            try? store.db.execute("DROP TABLE IF EXISTS \(table); DROP TABLE IF EXISTS \(members);")
            throw error
        }
    }

    // CROSS JOIN keeps the queue's rowid range outside file-state index lookups.
    var pageSQL: String {
        let columns = IndexStore.fileColumns.split(separator: ",").map { "f." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
        return """
            SELECT \(columns),q.priority,q.ord FROM \(table) q CROSS JOIN files f ON f.id=q.file
            WHERE q.ord>? AND f.state=? ORDER BY q.ord LIMIT ?
            """
    }

    func append(_ ids: [Int64]) throws {
        guard !closed, !ids.isEmpty else { return }
        try store.db.transaction {
            for id in ids {
                try store.db.run("""
                    INSERT OR IGNORE INTO \(table)(ord,file,priority)
                    SELECT ?,id,1 FROM files WHERE id=? AND state=?\(scopeSQL)
                    """,[.int(lastOrdinal+1),.int(id),.text(state)] + scopeValues)
                try store.db.query("SELECT changes()") { if $0.int(0)>0 {total += 1;lastOrdinal += 1} }
            }
        }
        exhausted=false
    }

    func prioritize(_ path: String) {
        preferredPath=path
        buffer.removeAll(keepingCapacity:true)
        offset=0;after=0;exhausted=false
    }

    func peek() throws -> Entry? {
        guard !closed else { return nil }
        if offset == buffer.count {
            guard !exhausted else { return nil }
            buffer.removeAll(keepingCapacity: true)
            offset = 0
            let start = ProcessInfo.processInfo.systemUptime
            if let path=preferredPath {
                let ranges=IndexStore.pathRanges(under:path)
                let conditions=ranges.map {_ in "(f.path>=? AND f.path<?)"}.joined(separator:" OR ")
                let columns=IndexStore.fileColumns.split(separator:",").map {"f."+ $0.trimmingCharacters(in:.whitespaces)}.joined(separator:",")
                let values=ranges.flatMap {[SQLValue.text($0.from),.text($0.to)]}
                try store.db.query("""
                    SELECT \(columns),-1,q.ord FROM \(table) q CROSS JOIN files f ON f.id=q.file
                    WHERE f.state=? AND (\(conditions)) ORDER BY q.ord LIMIT ?
                    """,[.text(state)] + values + [.int(Int64(pageSize))]) {
                    buffer.append(Entry(file:IndexStore.record($0),priority:-1,ordinal:$0.int(9)))
                }
                if buffer.isEmpty {preferredPath=nil;after=0}
            }
            if buffer.isEmpty {
                try store.db.query(pageSQL, [.int(after), .text(state), .int(Int64(pageSize))]) {
                    buffer.append(Entry(file: IndexStore.record($0), priority: Int($0.int(8)),ordinal:$0.int(9)))
                    after = $0.int(9)
                }
            }
            pages += 1
            rows += buffer.count
            peakBufferedRecords = max(peakBufferedRecords, buffer.count)
            fetchMs += (ProcessInfo.processInfo.systemUptime - start) * 1000
            if buffer.isEmpty { exhausted = true; return nil }
        }
        return buffer[offset]
    }

    func take() throws -> Entry? {
        guard let entry = try peek() else { return nil }
        try store.db.run("DELETE FROM \(table) WHERE ord=?",[.int(entry.ordinal)])
        offset += 1
        return entry
    }

    func takeBatch() throws -> (files: [FileRecord], priority: Int)? {
        guard let first = try take() else { return nil }
        var files = [first.file]
        if first.file.kind == .image || first.file.kind == .screenshot {
            while files.count < 8, let next = try peek(),
                  next.priority == first.priority, next.file.kind == first.file.kind {
                _ = try take()
                files.append(next.file)
            }
        }
        return (files, first.priority)
    }

    func longFileUnits() throws -> Int {
        var count = 0
        try store.db.query("""
            SELECT COALESCE(SUM(MAX(1,
                COALESCE(CAST(json_extract(f.info,'$.read_end') AS INTEGER),0) -
                COALESCE(CAST(json_extract(f.info,'$.read_to') AS INTEGER),
                    (SELECT MAX(loc) FROM segments WHERE file=f.id AND kind IN ('page','page_image','chunk')),0)
            )),0)
            FROM \(table) q JOIN files f ON f.id=q.file WHERE f.state='partial'
            """) { count = Int($0.int(0)) }
        return count
    }

    func remainingPriorityIDs() throws -> Set<Int64> {
        var result: Set<Int64> = []
        try store.db.query("""
            SELECT f.id FROM \(members) p CROSS JOIN files f ON f.id=p.file
            WHERE f.state=?\(scopeSQL)
            """, [.text(state)] + scopeValues) { result.insert($0.int(0)) }
        return result
    }

    func decorate(_ snapshot: inout IndexPipelineSnapshot) {
        snapshot.queueBuildMs += buildMs
        snapshot.queueFetchMs += fetchMs
        snapshot.queuePages += pages
        snapshot.queueRows += rows
        snapshot.peakBufferedRecords += peakBufferedRecords
    }

    func close() {
        guard !closed else { return }
        closed = true
        buffer.removeAll()
        try? store.db.execute("DROP TABLE IF EXISTS \(table); DROP TABLE IF EXISTS \(members);")
    }
}
