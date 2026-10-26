import Foundation

public struct IndexScanProgress {
    public let eligibleIDs: [Int64]
    public let queuedIDs: [Int64]
}

/// All calls, including close, stay on the index coordinator.
public final class IndexScanSession {
    private let store: IndexStore
    private let roots: [URL]
    private let rootSpellings: [(String,[String])]
    private let original: String
    private let seen: String
    private let deferred: String
    private let ready: String
    private var readyAfter: Int64 = 0
    public private(set) var eligibleCount = 0
    private var closed = false
    private var added = 0, changed = 0, moved = 0, removed = 0, unchanged = 0
    public private(set) var queuedCount = 0
    private var smallDemand: [Int64] = []

    init(store: IndexStore, roots: [URL]) throws {
        self.store = store
        self.roots = roots
        rootSpellings=roots.map {root in
            let path=root.standardizedFileURL.path
            return (path,IndexStore.pathRanges(under:path).map {range in
                range.from.hasSuffix("/") ? String(range.from.dropLast()) : range.from
            })
        }
        let suffix = UUID().uuidString.replacingOccurrences(of:"-",with:"")
        original = "digup_scan_original_" + suffix
        seen = "digup_scan_seen_" + suffix
        deferred = "digup_scan_deferred_" + suffix
        ready = "digup_scan_ready_" + suffix
        try store.db.execute("""
            CREATE TEMP TABLE \(original)(id INTEGER PRIMARY KEY,path TEXT UNIQUE,kind TEXT,size INTEGER,
                mtime REAL,inode INTEGER,device INTEGER);
            CREATE INDEX \(original)_identity ON \(original)(device,inode);
            CREATE TEMP TABLE \(seen)(path TEXT PRIMARY KEY);
            CREATE TEMP TABLE \(ready)(ord INTEGER PRIMARY KEY,file INTEGER UNIQUE);
            CREATE TEMP TABLE \(deferred)(id INTEGER PRIMARY KEY,path TEXT UNIQUE,kind TEXT,size INTEGER,
                mtime REAL,inode INTEGER,device INTEGER);
            """)
        do {
            try store.db.transaction {
                for root in roots {
                    for range in IndexStore.pathRanges(under:root.standardizedFileURL.path) {
                        try store.db.run("""
                            INSERT OR IGNORE INTO \(original)
                            SELECT id,path,kind,size,mtime,inode,device FROM files WHERE path>=? AND path<?
                            """,[.text(range.from),.text(range.to)])
                    }
                }
            }
        } catch { close(); throw error }
    }

    private func record(_ candidate: Candidate) -> [SQLValue] {
        [.text(candidate.path),.text(candidate.kind.rawValue),.int(candidate.size),.double(candidate.mtime),
         .int(Int64(bitPattern:candidate.inode)),.int(Int64(bitPattern:candidate.device))]
    }

    private func queued(_ id: Int64) {
        queuedCount += 1
        if smallDemand.count < 51 { smallDemand.append(id) }
    }

    public func admit(_ candidates: [Candidate]) throws -> IndexScanProgress {
        guard !closed else { throw Database.Failure(message:"The scan session has ended.") }
        guard candidates.count <= 256 else { throw Database.Failure(message:"The scan batch is too large.") }
        var eligible: [Int64] = [], fresh: [Int64] = []
        var add = 0, change = 0, same = 0
        try store.db.transaction {
            for candidate in candidates {
                try store.db.run("INSERT OR IGNORE INTO \(seen)(path) VALUES(?)",[.text(candidate.path)])
                var first = false
                try store.db.query("SELECT changes()") { first = $0.int(0) != 0 }
                if !first { continue }
                var existing: FileRecord?
                try store.db.query("SELECT \(IndexStore.fileColumns) FROM files WHERE path=?",[.text(candidate.path)]) {
                    existing = IndexStore.record($0)
                }
                if let row = existing {
                    let identityChanged = row.inode != 0 && candidate.inode != 0
                        && (row.inode != candidate.inode || row.device != candidate.device)
                    if row.size != candidate.size || abs(row.mtime-candidate.mtime)>0.001 || row.kind != candidate.kind || identityChanged {
                        try store.requeue(row.id,as:candidate)
                        change += 1
                        fresh.append(row.id)
                    } else { same += 1 }
                    eligible.append(row.id)
                } else {
                    var identityMatch = false
                    if candidate.inode != 0 {
                        try store.db.query("""
                            SELECT EXISTS(SELECT 1 FROM \(original) WHERE device=? AND inode=?)
                            """,[.int(Int64(bitPattern:candidate.device)),.int(Int64(bitPattern:candidate.inode))]) {
                            identityMatch = $0.int(0) != 0
                        }
                    }
                    if identityMatch {
                        try store.db.run("INSERT INTO \(deferred)(path,kind,size,mtime,inode,device) VALUES(?,?,?,?,?,?)",record(candidate))
                    } else {
                        let id = try store.insert(candidate)
                        eligible.append(id); fresh.append(id); add += 1
                    }
                }
            }
        }
        for id in eligible { try enqueue(id) }
        added += add; changed += change; unchanged += same
        for id in fresh { queued(id) }
        return IndexScanProgress(eligibleIDs:eligible,queuedIDs:fresh)
    }

    private func enqueue(_ id: Int64) throws {
        try store.db.run("INSERT OR IGNORE INTO \(ready)(file) VALUES(?)",[.int(id)])
        try store.db.query("SELECT changes()") { eligibleCount += Int($0.int(0)) }
    }

    public func takeEligibleIDs(limit: Int = 128) throws -> [Int64] {
        var result: [Int64] = []
        try store.db.query("SELECT ord,file FROM \(ready) WHERE ord>? ORDER BY ord LIMIT ?",
            [.int(readyAfter),.int(Int64(max(1,min(256,limit))))]) {
            readyAfter=$0.int(0);result.append($0.int(1))
        }
        return result
    }

    public func finish(_ report: CrawlReport) throws -> Indexer.SyncSummary {
        guard !closed else { throw Database.Failure(message:"The scan session has ended.") }
        func aliases(_ path: String) -> [String] {
            var values=[path,FolderSelection.realPath(path)]
            for (root,spellings) in rootSpellings where path==root || FolderSelection.isInside(path,root) {
                values += spellings.map {$0+String(path.dropFirst(root.count))}
            }
            return values
        }
        let unavailable=Array(report.unreadable).flatMap(aliases)
            + roots.filter {!FileManager.default.fileExists(atPath:$0.path)}.flatMap {aliases($0.standardizedFileURL.path)}
        func protected(_ path: String) -> Bool {
            unavailable.contains { path == $0 || FolderSelection.isInside(path,$0) }
        }
        var deferredAfter: Int64 = 0
        while true {
            var batch: [(Int64,Candidate)] = []
            try store.db.query("""
                SELECT id,path,kind,size,mtime,inode,device FROM \(deferred) WHERE id>? ORDER BY id LIMIT 64
                """,[.int(deferredAfter)]) { row in
                guard let path=row.text(1),let kind=FileKind(rawValue:row.text(2) ?? "") else{return}
                batch.append((row.int(0),Candidate(path:path,kind:kind,size:row.int(3),mtime:row.double(4),
                    inode:UInt64(bitPattern:row.int(5)),device:UInt64(bitPattern:row.int(6)))))
            }
            if batch.isEmpty { break }
            try store.db.transaction {
                for (ordinal,candidate) in batch {
                    deferredAfter = ordinal
                    var matches: [(Int64,String)] = []
                    try store.db.query("""
                        SELECT o.id,o.path FROM \(original) o
                        JOIN files f ON f.id=o.id AND f.path=o.path
                        WHERE o.device=? AND o.inode=? AND o.kind=? AND o.size=? AND ABS(o.mtime-?)<0.001
                        AND NOT EXISTS(SELECT 1 FROM \(seen) s WHERE s.path=o.path)
                        """,[.int(Int64(bitPattern:candidate.device)),.int(Int64(bitPattern:candidate.inode)),
                             .text(candidate.kind.rawValue),.int(candidate.size),.double(candidate.mtime)]) {
                        matches.append(($0.int(0),$0.text(1) ?? ""))
                    }
                    let usable = matches.filter { !protected($0.1) }
                    var destinations=0
                    try store.db.query("SELECT COUNT(*) FROM \(deferred) WHERE device=? AND inode=?",
                        [.int(Int64(bitPattern:candidate.device)),.int(Int64(bitPattern:candidate.inode))]) {
                        destinations=Int($0.int(0))
                    }
                    if usable.count == 1 && destinations == 1, let match=usable.first {
                        try store.move(match.0,to:candidate.path)
                        moved += 1
                        try enqueue(match.0)
                    } else {
                        let id=try store.insert(candidate)
                        added += 1; queued(id); try enqueue(id)
                    }
                }
            }
        }
        var after: Int64 = 0
        while true {
            var batch: [(Int64,String)] = []
            try store.db.query("""
                SELECT o.id,o.path FROM \(original) o JOIN files f ON f.id=o.id AND f.path=o.path
                WHERE o.id>? AND NOT EXISTS(SELECT 1 FROM \(seen) s WHERE s.path=o.path) ORDER BY o.id LIMIT 128
                """,[.int(after)]) { batch.append(($0.int(0),$0.text(1) ?? "")) }
            if batch.isEmpty { break }
            try store.db.transaction {
                for (id,path) in batch {
                    after=id
                    if !protected(path) { try store.delete(id); removed += 1 }
                }
            }
        }
        var summary = Indexer.SyncSummary(crawl:report)
        summary.added=added;summary.changed=changed;summary.moved=moved
        summary.removed=removed;summary.unchanged=unchanged;summary.queued=smallDemand
        return summary
    }

    public func close() {
        if closed { return }
        closed=true
        try? store.db.execute("DROP TABLE IF EXISTS \(original); DROP TABLE IF EXISTS \(seen); DROP TABLE IF EXISTS \(deferred); DROP TABLE IF EXISTS \(ready);")
    }
}
