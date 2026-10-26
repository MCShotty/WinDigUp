import DigUpKit
import Foundation
import LlamaRuntime

/// Version 2 JSON-lines search protocol. The input reader only admits bounded work; it never owns inference,
/// preview slots or database scans. Each SQLite connection and Searcher has exactly one serial owner.
final class SearchService: @unchecked Sendable {
    private let directory: URL, baseDirectory: URL
    private var store: IndexStore
    private var searcher: Searcher
    private var codeStore: IndexStore?
    private var codeSearcher: Searcher?
    private var semanticStore: IndexStore?, semanticCodeStore: IndexStore?
    private var semanticSearcher: Searcher?, semanticCodeSearcher: Searcher?
    private var roots: [String], skipped: [String], types: Set<String>, codeRoots: [String], codeSkipped: [String]
    private let idleSeconds: Double
    private let availability: FileAvailability
    private let log: URL
    private var encoder: (any Embedder)?
    private var encoderState = "stopped"
    private var encoderPerformedInference = false
    private var vectorCache: [String: [Float]] = [:]
    private var cacheOrder: [String] = []
    private var lastEncodingTimings: [String: Any] = [:]
    private var lastQuery = ProcessInfo.processInfo.systemUptime
    private let preparationOwner=UUID().uuidString
    private var applicationStore: ApplicationStore?
    private var windowsSettingsStore: ApplicationStore?
    private var settingsReceipt: [String: Any] = ["state": "preparing", "encoder": "stopped"]
    private var encoderError: String?
    private let stateLock = NSLock(), configLock = NSLock(), output = NSLock()
    private var generations: [String: UInt64] = [:]
    private var sessionTouched: [String: Double] = [:]
    private var encoderReceipt: [String: Any] = ["state": "stopped"]
    private var applicationReceipt: [String: Any] = ["state": "preparing", "encoder": "stopped"]
    private var activeWorker: EmbeddingWorker?
    private var loadingProcess: Process?
    private var refreshing = false, refreshAgain = false, refreshVectors = false
    private var snapshotBytes = 0, snapshotRevision: UInt64 = 0
    private var snapshotError: String?
    private var stopping = false
    private let lexical = SearchWorkQueue(), inference = SearchWorkQueue(), retrieval = SearchWorkQueue()
    private let maintenance = SearchWorkQueue(), loader = SearchWorkQueue()
    private let previewsQueue = SearchWorkQueue(concurrency: 2, capacity: 32)
    private let previews: URL
    private var rendered: [String: String] = [:]
    // Maintenance owns these readers/caches; data_version changes when indexing commits on another connection.
    private var summaryReaders: [Bool: IndexStore] = [:]
    private var summaryCache: [Bool: (version: Int64, roots: [String], values: [[String: Any]])] = [:]
    private let renderLock = NSLock()
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    init(
        index: URL, baseIndex: URL, roots: [String], skipped: [String], types: Set<String>, codeRoots: [String],
        codeSkipped: [String], idleSeconds: Double,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws {
        directory = index
        baseDirectory = baseIndex
        // The initial writer creates/migrates once. Subsequent lanes open readers without WAL negotiation.
        store = try IndexStore(directory: index)
        searcher = try Searcher(store: store, loadVectors: false)
        self.roots = roots
        self.skipped = skipped
        self.types = types
        self.codeRoots = codeRoots
        self.codeSkipped = codeSkipped
        self.idleSeconds = idleSeconds
        self.availability = FileAvailability(probe: fileExists)
        log = index.appendingPathComponent("worker-query.log")
        previews = index.appendingPathComponent("previews")
        try? FileManager.default.removeItem(at: previews)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try openCode()
    }
    private func openCode() throws {
        guard !codeRoots.isEmpty else { return }
        let code = try IndexStore(directory: directory, file: IndexStore.codeFile)
        codeStore = code
        codeSearcher = try Searcher(store: code, loadVectors: false)
    }
    func serve() -> Int32 {
        Thread.detachNewThread { [self] in idleWatch() }
        requestRefresh(vectors: false)
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if fields["op"] as? String == "quit" {
                write(["id": fields["id"] ?? NSNull(), "ok": true])
                break
            }
            admit(SearchMessage(fields))
        }
        stateLock.withLock {
            stopping = true
            activeWorker?.interrupt()
            if let loadingProcess { EmbeddingWorker.interrupt(loadingProcess) }
        }
        availability.stop()
        for queue in [lexical, inference, retrieval, maintenance, loader, previewsQueue] { queue.stop() }
        return 0
    }
    private func current(_ request: SearchMessage) -> Bool {
        guard let session = request.fields["session"] as? String,
            let generation = request.fields["generation"] as? UInt64
        else { return true }
        return stateLock.withLock { !stopping && generations[session] == generation }
    }
    private func finish(
        _ request: SearchMessage, _ result: [String: Any], admitted: Double,
        started: Double? = nil, phase: String = "control"
    ) {
        var reply = result
        reply["id"] = request.fields["id"] ?? NSNull()
        reply["protocol_version"] = 2
        for key in ["session", "generation", "phase"] { if let value = request.fields[key] { reply[key] = value } }
        if !current(request) {
            reply = [
                "id": reply["id"]!, "session": reply["session"] ?? "", "generation": reply["generation"] ?? 0,
                "protocol_version": 2, "ok": true, "status": "superseded", "hits": [], "strong": 0,
            ]
        }
        var timing = reply["ms"] as? [String: Any] ?? [:]
        timing["queue"] = ((started ?? Self.now) - admitted) * 1000
        timing["helper_total"] = (Self.now - admitted) * 1000
        reply["ms"] = timing
        reply["phase"] = reply["phase"] ?? phase
        write(reply)
    }
    private func admit(_ request: SearchMessage) {
        let r = request.fields
        let admitted = Self.now
        let op = r["op"] as? String ?? ""
        let session = r["session"] as? String
        if let session, let generation = r["generation"] as? UInt64 {
            let valid = stateLock.withLock { () -> Bool in
                guard session.count <= 128 else { return false }
                if generations[session] == nil, generations.count >= 64,
                    let oldest = sessionTouched.min(by: { $0.value < $1.value })?.key
                {
                    generations.removeValue(forKey: oldest)
                    sessionTouched.removeValue(forKey: oldest)
                }
                sessionTouched[session] = Self.now
                generations[session] = max(generation, generations[session] ?? 0)
                return true
            }
            if !valid {
                finish(request, ["ok": false, "error": "Invalid or excessive search sessions"], admitted: admitted)
                return
            }
        }
        if op == "cancel" {
            finish(request, ["ok": true], admitted: admitted)
            return
        }
        if !current(request) {
            finish(request, ["ok": true, "status": "superseded"], admitted: admitted)
            return
        }
        let identifier = "request:\(r["id"] ?? UUID().uuidString)"
        let key =
            op == "render"
            ? "\(session ?? "preview"):\(r["path"] ?? ""):\(r["loc"] ?? ""):\(r["pixels"] ?? "")"
            : r["generation"] == nil ? identifier : session ?? identifier
        let cancel: @Sendable () -> Void = { [self] in
            var value = stateLock.withLock { applicationReceipt }
            value["ok"] = true
            value["status"] = "superseded"
            value["hits"] = []
            value["strong"] = 0
            finish(request, value, admitted: admitted)
        }
        if op == "render" {
            previewsQueue.submit(
                key: key, foreground: r["foreground"] as? Bool ?? ((r["pixels"] as? Int ?? 1024) > 512), cancel: cancel
            ) { [self] in
                let started = Self.now
                guard current(request) else {
                    cancel()
                    return
                }
                do { finish(request, try render(r), admitted: admitted, started: started, phase: "preview") } catch {
                    finish(request, ["ok": false, "error": "\(error)"], admitted: admitted, started: started)
                }
            }
            return
        }
        if op == "prewarm" {
            if stateLock.withLock({ snapshotBytes == 0 }) { requestRefresh(vectors: true) }
        } else if op == "reload" {
            requestRefresh(vectors: stateLock.withLock { snapshotBytes > 0 })
            finish(request, ["ok": true, "scheduled": true], admitted: admitted)
            return
        }
        if op == "summaries" {
            maintenance.submit(key: "summaries:\(r["code"] as? Bool ?? false)", foreground: false, cancel: cancel) {
                [self] in
                let started = Self.now
                do {
                    let code = r["code"] as? Bool ?? false
                    let db: IndexStore
                    if let existing = summaryReaders[code] {
                        db = existing
                    } else {
                        db = try IndexStore(
                            directory: directory, file: code ? IndexStore.codeFile : IndexStore.mainFile, readOnly: true
                        )
                        summaryReaders[code] = db
                    }
                    let selected = configLock.withLock { code ? codeRoots : roots }
                    try db.db.execute("BEGIN")
                    defer { try? db.db.execute("ROLLBACK") }
                    var version: Int64 = 0
                    try db.db.query("PRAGMA data_version") { version = $0.int(0) }
                    let values: [[String: Any]]
                    if let cached = summaryCache[code], cached.version == version, cached.roots == selected {
                        values = cached.values.map { value in
                            var value = value
                            let folder = URL(fileURLWithPath: value["path"] as? String ?? "")
                            let missing = !Arguments.isFolder(folder)
                            value["missing"] = missing
                            value["unreadable"] = !missing && !Arguments.isReadable(folder)
                            return value
                        }
                    } else {
                        values = selected.map { summary(of: $0, in: db) }
                        summaryCache[code] = (version, selected, values)
                    }
                    finish(
                        request, ["roots": values], admitted: admitted,
                        started: started)
                } catch { finish(request, ["ok": false, "error": "\(error)"], admitted: admitted, started: started) }
            }
            return
        }
        let neural =
            op.hasPrefix("apps_") || op.hasPrefix("settings_") || op == "prewarm" || op == "embed_ahead"
            || (op == "search" && (r["meaning"] as? Bool ?? true) && !(r["q"] as? String ?? "").isEmpty)
        let queue = neural ? inference : lexical
        queue.submit(
            key: op == "prewarm" ? "prewarm" : op.hasSuffix("_index_step") ? "\(op)-background" : key,
            foreground: !op.hasSuffix("_index_step") && !(r["passive"] as? Bool ?? false), cancel: cancel
        ) { [self] in
            let started = Self.now
            guard current(request) else {
                cancel()
                return
            }
            do {
                if neural && op == "search" {
                    let vector = vector(
                        for: r["q"] as? String ?? "", code: r["code"] as? Bool ?? false,
                        active: !(r["passive"] as? Bool ?? false))
                    let source = encoder?.info.vectorSource
                    let encoding = SearchMessage(lastEncodingTimings)
                    let encoded = Self.now
                    guard current(request) else {
                        cancel()
                        return
                    }
                    let values = SearchVector(values: vector, source: source)
                    retrieval.submit(key: key, cancel: cancel) { [self] in
                        guard current(request) else {
                            cancel()
                            return
                        }
                        do {
                            let code = r["code"] as? Bool ?? false
                            if values.values != nil, let index = code ? semanticCodeSearcher : semanticSearcher {
                                var result = try fileSearch(r, in: index, vector: values.values, source: values.source)
                                var ms = result["ms"] as? [String: Any] ?? [:]
                                ms.merge(encoding.fields) { $1 }
                                ms["retrieval_queue"] = max(
                                    0, (Self.now - encoded) * 1000 - (ms["search"] as? Double ?? 0))
                                result["ms"] = ms
                                result["revision"] = snapshotRevision
                                finish(request, result, admitted: admitted, started: started, phase: "meaning")
                            } else {
                                if values.values != nil { requestRefresh(vectors: true) }
                                lexical.submit(key: key, cancel: cancel) { [self] in
                                    do {
                                        var reply = try fileSearch(
                                            r, in: (code ? codeSearcher : searcher), vector: nil, source: nil)
                                        let problem = stateLock.withLock {
                                            snapshotError
                                                ?? (encoderReceipt["state"] as? String == "unavailable"
                                                    ? encoderReceipt["error"] as? String : nil)
                                        }
                                        reply["preparing"] = values.values != nil && problem == nil
                                        if let problem { reply["semantic_error"] = problem }
                                        finish(request, reply, admitted: admitted, started: started, phase: "words")
                                    } catch {
                                        finish(
                                            request, ["ok": false, "error": "\(error)"], admitted: admitted,
                                            started: started)
                                    }
                                }
                            }
                        } catch {
                            finish(request, ["ok": false, "error": "\(error)"], admitted: admitted, started: started)
                        }
                    }
                } else {
                    finish(
                        request, try handle(op, r), admitted: admitted, started: started,
                        phase: neural ? "meaning" : "words")
                }
            } catch {
                finish(
                    request, ["ok": false, "error": String("\(error)".prefix(500))], admitted: admitted,
                    started: started)
            }
        }
    }
    private struct SearchVector: Sendable {
        let values: [Float]?
        let source: String?
    }

    private func handle(_ op: String, _ request: [String: Any]) throws -> [String: Any] {
        switch op {
        case "search":
            return try fileSearch(
                request, in: (request["code"] as? Bool ?? false) ? codeSearcher : searcher, vector: nil, source: nil)
        case "embed_ahead":
            _ = vector(for: request["q"] as? String ?? "", code: request["code"] as? Bool ?? false)
            return ["ok": true]
        case "prewarm":
            lastQuery = Self.now
            _ = runningEncoder()
            return ["ok": true, "encoder": encoderState]
        case "apps_catalog", "settings_catalog":
            guard let revision = request["revision"] as? String,
                let documents = request["documents"] as? [[String: Any]]
            else { throw CLIError("invalid application catalog") }
            let db = try documentStore(settings: op.hasPrefix("settings_"))
            if db.revision != revision {
                try db.synchronize(
                    JSONDecoder().decode(
                        [ApplicationDocument].self, from: JSONSerialization.data(withJSONObject: documents)),
                    revision: revision)
            }
            return try applicationState(db, settings: op.hasPrefix("settings_"))
        case "apps_status", "settings_status": return try applicationState(documentStore(settings: op.hasPrefix("settings_")), settings: op.hasPrefix("settings_"))
        case "apps_index_step", "settings_index_step":
            let db = try documentStore(settings: op.hasPrefix("settings_"))
            guard let encoder, encoderState == "ready" else { return try applicationState(db, settings: op.hasPrefix("settings_")) }
            let fp = try applicationFingerprint(encoder, settings: op.hasPrefix("settings_"))
            try db.prepare(fingerprint: fp)
            if let claim = try db.claimPending(owner:preparationOwner) {
                let document=claim.document
                defer{try? db.release(claim)}
                do {
                    guard
                        let vector = try encoder.embedTexts([
                            Prompts.document(title: document.name, text: document.text)
                        ]).first
                    else { throw CLIError("No application vector returned") }
                    try db.save(vector,claim:claim)
                    recordInference(encoder)
                } catch {
                    failEncoder(error)
                    throw error
                }
            }
            return try applicationState(db, settings: op.hasPrefix("settings_"))
        case "apps_search", "settings_search":
            let db = try documentStore(settings: op.hasPrefix("settings_"))
            guard let revision = request["revision"] as? String, revision == db.revision else {
                return ["revision": db.revision, "hits": [], "state": "preparing"]
            }
            let text = request["q"] as? String ?? ""
            guard text.count <= 4096 else { throw CLIError("Application query is too long") }
            var reply = try applicationState(db, settings: op.hasPrefix("settings_"))
            reply["hits"] = []
            reply["meaning"] = false
            if !text.isEmpty,
                let vector = vector(for: text, code: false, active: !(request["passive"] as? Bool ?? false)),
                let encoder
            {
                let fp = try applicationFingerprint(encoder, settings: op.hasPrefix("settings_"))
                try db.prepare(fingerprint: fp)
                reply = try applicationState(db, settings: op.hasPrefix("settings_"))
                reply["meaning"] = true
                reply["hits"] = try db.search(
                    vector, fingerprint: fp,
                    minimumCosine: min(
                        max((request["minimum_cosine"] as? NSNumber)?.floatValue ?? ApplicationStore.minimumCosine, 0),
                        1)
                ).map { ["id": $0.id, "cosine": $0.cosine] as [String: Any] }
            } else {
                reply = try applicationState(db, settings: op.hasPrefix("settings_"))
                reply["hits"] = []
                reply["meaning"] = false
            }
            reply["ms"] = lastEncodingTimings
            return reply
        case "text":
            guard let id = (request["segment"] as? NSNumber)?.int64Value else { throw CLIError("Which segment?") }
            return [
                "text": try ((request["code"] as? Bool ?? false) ? codeSearcher : searcher)?.text(ofSegment: id)
                    ?? NSNull()
            ]
        case "folders":
            availability.clear()
            configLock.withLock {
                if let v = request["roots"] as? [String] { roots = v.map { Arguments.folderURL($0).path } }
                if let v = request["skipped"] as? [String] { skipped = v.map { Arguments.folderURL($0).path } }
                if let v = request["types"] as? [String] { types = IndexOptions.extensions(v.joined(separator: ",")) }
                if let v = request["code_roots"] as? [String] { codeRoots = v.map { Arguments.folderURL($0).path } }
                if let v = request["code_skipped"] as? [String] { codeSkipped = v.map { Arguments.folderURL($0).path } }
            }
            if configLock.withLock({ codeRoots.isEmpty }) {
                codeSearcher = nil
                codeStore = nil
                retrieval.submit(key: "close-code") { [self] in
                    semanticCodeSearcher = nil
                    semanticCodeStore = nil
                }
            } else if codeSearcher == nil {
                try openCode()
            }
            requestRefresh(vectors: false)
            return ["ok": true]
        case "status":
            var reply = stateLock.withLock { encoderReceipt }
            reply["encoder"] = reply.removeValue(forKey: "state") ?? "stopped"
            reply["index"] = store.file.path
            if let counts = try? store.counts() {
                var files = 0
                var searchable = 0
                var pending = 0
                for states in counts.byKindAndState.values {
                    for (state, count) in states {
                        files += count
                        if state == "done" || state == "partial" { searchable += count }
                        if state == "pending" { pending += count }
                    }
                }
                reply.merge([
                    "files": files, "searchable": searchable, "pending": pending, "unfinished": counts.unfinished,
                    "vectors": counts.vectors,
                ]) { $1 }
            }
            reply["refreshing"] = stateLock.withLock { refreshing }
            reply["availability"] = availability.snapshot
            return reply
        default: throw CLIError("Unknown op \(op)")
        }
    }
    func fileSearch(_ request: [String: Any], in index: Searcher?, vector: [Float]?, source: String?) throws
        -> [String: Any]
    {
        let text = request["q"] as? String ?? ""
        guard text.count <= 4096 else { throw CLIError("Query is too long") }
        guard let index else { return ["hits": [], "strong": 0, "meaning": false] }
        let started = Self.now
        let code = request["code"] as? Bool ?? false
        let kinds = (request["kinds"] as? [String]).map { Set($0.compactMap(FileKind.init(rawValue:))) }
        var vector = vector
        var warning: String?
        if vector != nil, index.vectorSource != source {
            vector = nil
            warning = "Meaning search is unavailable for incompatible index vectors"
        }
        var options = configLock.withLock { (code ? codeRoots : roots, code ? codeSkipped : skipped, types) }
        if let value = request["file_scope"] {
            guard let scope = value as? [String: Any], scope["version"] as? Int == 1,
                let selected = scope["roots"] as? [String], let exclusions = scope["skipped"] as? [String],
                let extensions = scope["types"] as? [String]
            else { throw CLIError("Invalid explicit search scope") }
            options = (selected.map { Arguments.folderURL($0).path },
                       exclusions.map { Arguments.folderURL($0).path }, IndexOptions.extensions(extensions.joined(separator: ",")))
            if options.0.isEmpty {
                return ["hits": [], "strong": 0, "meaning": false, "facets": [:],
                        "scope_empty": true, "exact_filename_known": true, "exact_filename": false,
                        "count_scope": "ranked_candidates", "ms": ["search": (Self.now - started) * 1000]]
            }
        }
        var availabilityMs = 0.0
        var observations: [String: FileAvailability.Observation] = [:]
        func observation(_ path: String) -> FileAvailability.Observation {
            if let value = observations[path] { return value }
            let began = Self.now
            let value = availability.observation(path)
            availabilityMs += (Self.now - began) * 1000
            observations[path] = value
            return value
        }
        let exactNames = try index.exactNamePaths(text)
        let exactCollision =
            exactNames?.contains { path in
                (options.0.isEmpty || FolderSelection.isSearched(path, folders: options.0, skipped: options.1))
                    && !options.2.contains((path as NSString).pathExtension.lowercased())
            } ?? false
        if code && options.0.isEmpty { return ["hits": [], "strong": 0, "meaning": false] }
        let hits = try index.search(
            text, queryVector: vector, kinds: kinds, limit: min(max(request["limit"] as? Int ?? 40, 1), 200),
            prefixLast: request["prefix_last"] as? Bool ?? false,
            includeFacets: request["facets"] as? Bool ?? false
        ).filter {
            (options.0.isEmpty || FolderSelection.isSearched($0.path, folders: options.0, skipped: options.1))
                && (code || !options.2.contains(($0.path as NSString).pathExtension.lowercased()))
        }
        for hit in hits { _ = observation(hit.path) }
        var timing = index.timings
        timing["availability"] = availabilityMs
        timing["search"] = (Self.now - started) * 1000
        var reply: [String: Any] = [
            "hits": hits.map { hit in
                var fields = hitFields(hit)
                if let value = observations[hit.path] { fields.merge(value.fields) { $1 } }
                return fields
            }, "strong": Searcher.strongCount(hits), "meaning": vector != nil,
            "ms": timing, "facets": index.facetCounts, "count_scope": "ranked_candidates",
            "category_query": Searcher.terms(text).isEmpty && !Searcher.kindHints(text).isEmpty,
            "exact_filename_known": exactNames != nil, "exact_filename": exactCollision,
            "availability_checks": observations.count,
        ]
        if let warning { reply["warning"] = warning }
        return reply
    }
    private func requestRefresh(vectors: Bool) {
        let begin = stateLock.withLock { () -> Bool in
            refreshVectors = refreshVectors || vectors
            if refreshing {
                refreshAgain = true
                return false
            }
            refreshing = true
            return true
        }
        guard begin else { return }
        loader.submit(key: "refresh", foreground: false) { [self] in
            let started = Self.now
            let load = stateLock.withLock {
                let v = refreshVectors
                refreshVectors = false
                return v
            }
            do {
                let main = try IndexStore(directory: directory, readOnly: true)
                let words = try Searcher(store: main, loadVectors: false, loadNames: true)
                let hasCode = configLock.withLock { !codeRoots.isEmpty }
                let code =
                    try hasCode ? IndexStore(directory: directory, file: IndexStore.codeFile, readOnly: true) : nil
                let codeWords = try code.map { try Searcher(store: $0, loadVectors: false) }
                let wordsPublished = DispatchSemaphore(value: 0)
                lexical.submit(key: "publish-words", foreground: false, cancel: { wordsPublished.signal() }) { [self] in
                    let retired = RetiredWords(main: searcher, code: codeSearcher)
                    store = main
                    searcher = words
                    codeStore = code
                    codeSearcher = codeWords
                    // Releasing a large name dictionary can take longer than the pointer swap. Retire it away
                    // from the keyword owner; the old readers have no remaining users after this serial handoff.
                    DispatchQueue.global(qos: .utility).async { withExtendedLifetime(retired) {} }
                    write(["event": "search_index", "state": "words_ready"])
                    wordsPublished.signal()
                }
                wordsPublished.wait()
                if load {
                    let db = try IndexStore(directory: directory, readOnly: true)
                    // The read transaction pins vector rows AND their metadata to the same SQLite revision.
                    try db.db.execute("BEGIN")
                    var count: Int64 = 0
                    try db.db.query("SELECT count(*) FROM segments WHERE vec IS NOT NULL") { count = $0.int(0) }
                    let codeDB =
                        try hasCode ? IndexStore(directory: directory, file: IndexStore.codeFile, readOnly: true) : nil
                    try codeDB?.db.execute("BEGIN")
                    try codeDB?.db.query("SELECT count(*) FROM segments WHERE vec IS NOT NULL") { count += $0.int(0) }
                    var files: Int64 = 0
                    try db.db.query("SELECT count(*) FROM files") { files += $0.int(0) }
                    try codeDB?.db.query("SELECT count(*) FROM files") { files += $0.int(0) }
                    let bytes =
                        Int(min(count, Int64(Int.max / 3200))) * 1600 + Int(min(files, Int64(Int.max / 1536))) * 768 + 8
                        * 1024 * 1024
                    let budget = Int(min(ProcessInfo.processInfo.physicalMemory / 4, 4 * 1024 * 1024 * 1024))
                    guard bytes <= budget else {
                        throw CLIError("Search vectors exceed the host-memory budget; keyword search remains available")
                    }
                    if stateLock.withLock({ snapshotBytes }) + bytes > budget {
                        let drained = DispatchSemaphore(value: 0)
                        retrieval.submit(key: "release", foreground: false, cancel: { drained.signal() }) { [self] in
                            semanticSearcher = nil
                            semanticCodeSearcher = nil
                            semanticStore = nil
                            semanticCodeStore = nil
                            stateLock.withLock { snapshotBytes = 0 }
                            drained.signal()
                        }
                        drained.wait()
                    }
                    let semantic = try Searcher(store: db)
                    let codeSemantic = try codeDB.map { try Searcher(store: $0) }
                    let vectorsPublished = DispatchSemaphore(value: 0)
                    retrieval.submit(key: "publish-vectors", foreground: false, cancel: { vectorsPublished.signal() }) {
                        [self] in
                        semanticStore = db
                        semanticSearcher = semantic
                        semanticCodeStore = codeDB
                        semanticCodeSearcher = codeSemantic
                        stateLock.withLock {
                            snapshotBytes = bytes
                            snapshotRevision += 1
                            snapshotError = nil
                        }
                        write([
                            "event": "search_index", "state": "ready", "revision": snapshotRevision,
                            "vectors": semantic.vectorCount,
                            "ms": ["vector_load": (Self.now - started) * 1000],
                        ])
                        vectorsPublished.signal()
                    }
                    vectorsPublished.wait()
                }
            } catch {
                stateLock.withLock { snapshotError = String("\(error)".prefix(500)) }
                write(["event": "search_index", "state": "unavailable", "error": "\(error)"])
            }
            let again = stateLock.withLock { () -> Bool in
                refreshing = false
                let a = refreshAgain
                refreshAgain = false
                return a
            }
            if again { requestRefresh(vectors: stateLock.withLock { refreshVectors || snapshotBytes > 0 }) }
        }
    }
    private struct RetiredWords: @unchecked Sendable {
        let main: Searcher
        let code: Searcher?
    }
    private func write(_ fields: [String: Any]) {
        if fields["event"] as? String == "encoder" { stateLock.withLock { encoderReceipt = fields } }
        output.withLock { emit(fields) }
    }
    private func summary(of root: String, in store: IndexStore?) -> [String: Any] {
        let folder = URL(fileURLWithPath: root)
        let missing = !Arguments.isFolder(folder)
        var fields: [String: Any] = [
            "path": root, "missing": missing, "unreadable": !missing && !Arguments.isReadable(folder),
        ]
        var states = ["indexed": 0, "pending": 0, "failed": 0, "skipped": 0, "unfinished": 0]
        var kinds: [String: Int] = [:]
        let files = (try? store?.files(under: [root])) ?? []
        for file in files {
            kinds[file.kind.rawValue, default: 0] += 1
            switch file.state {
            case "done": states["indexed", default: 0] += 1
            case "partial":
                states["indexed", default: 0] += 1
                states["unfinished", default: 0] += 1
            case "pending": states["pending", default: 0] += 1
            case "failed": states["failed", default: 0] += 1
            default: states["skipped", default: 0] += 1
            }
        }
        fields.merge(states) { $1 }
        fields["files"] = files.count
        fields["kinds"] = kinds
        return fields
    }

    // MARK: Previews

    private func render(_ request: [String: Any]) throws -> [String: Any] {
        guard let path = request["path"] as? String else { throw CLIError("which file?") }
        let kind = request["kind"] as? String ?? "image"
        let loc = (request["loc"] as? NSNumber)?.doubleValue
        let pixels = min(max(request["pixels"] as? Int ?? 1024, 32), 2048)
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(path)|\(modified)|\(kind)|\(loc ?? -1)|\(pixels)"
        if let done = renderLock.withLock({ rendered[key] }), FileManager.default.fileExists(atPath: done) {
            return ["image": done]
        }
        let image = try PreviewImages.make(
            PreviewImages.Kind(rawValue: kind) ?? .image, of: path, at: loc,
            pixels: pixels, in: previews)
        renderLock.withLock {
            rendered[key] = image
            if rendered.count > 256, let oldest = rendered.keys.first { rendered.removeValue(forKey: oldest) }
        }
        return ["image": image]
    }

    private func documentStore(settings: Bool) throws -> ApplicationStore {
        if settings {
            if let windowsSettingsStore { return windowsSettingsStore }
            let db = try WindowsSettingsStore.recovering(directory: directory)
            windowsSettingsStore = db
            return db
        }
        return try applications()
    }

    private func applications() throws -> ApplicationStore {
        if let applicationStore { return applicationStore }
        let store = try ApplicationStore.recovering(directory: directory)
        applicationStore = store
        return store
    }

    private func applicationFingerprint(_ worker: any Embedder, settings: Bool = false) throws -> String {
        let backend = try Acceleration.selected()
        return ApplicationStore.fingerprint(
            info: worker.info, backend: backend.rawValue,
            runtimeBuild: backend == .openvinoNPU
                ? "" : backend == .nvidiaCUDA ? LlamaEmbedder.buildIdentity : LlamaEmbedder.buildTag,
            documentPromptVersion: settings ? WindowsSettingsStore.promptVersion : ApplicationStore.promptVersion)
    }

    private func applicationState(_ store: ApplicationStore, settings: Bool = false) throws -> [String: Any] {
        let counts = try store.counts()
        let state =
            encoderState == "unavailable"
            ? "unavailable"
            : counts.embedded < counts.total || encoderState != "ready" ? "preparing" : "ready"
        var reply: [String: Any] = [
            "ok": true, "revision": store.revision, "state": state,
            "total": counts.total, "embedded": counts.embedded, "encoder": encoderState,
            "inference_verified": encoderPerformedInference,
            "ranking_version": ApplicationStore.rankingVersion, "ranking_calibrated": false,
        ]
        if let encoder {
            reply["fingerprint"] = try applicationFingerprint(encoder, settings: settings)
            reply["device"] = encoder.info.device ?? ""
            reply["execution_policy"] = encoder.info.executionPolicy ?? ""
            for (key, value) in encoder.info.fields
            where [
                "backend", "device_id", "driver_version", "runtime_version", "precision_profile", "build_identity",
                "model", "revision", "runtime", "dtype", "dim",
            ]
            .contains(key) { reply[key] = value }
        }
        if let encoderError { reply["message"] = encoderError }
        stateLock.withLock { if settings { settingsReceipt = reply } else { applicationReceipt = reply } }
        return reply
    }

    /// The query's vector (cached), or nil when the encoder can't run: keyword results still work.
    private func vector(for text: String, code: Bool, active: Bool = true) -> [Float]? {
        if !active && encoder == nil {
            lastEncodingTimings = ["encode": 0, "model_load": 0]
            return nil
        }
        if active { lastQuery = Self.now }
        let loading = Self.now
        let cold = encoder == nil
        guard let encoder = runningEncoder() else {
            lastEncodingTimings = ["model_load": (Self.now - loading) * 1000]
            return nil
        }
        let ready = Self.now
        let info = encoder.info
        let key = [
            info.model, info.revision, info.runtime, info.dtype, String(info.dim),
            info.backend ?? Acceleration.cacheKey,
            info.precisionProfile ?? "", info.buildIdentity ?? "", "text512",
            code ? Prompts.codeQuery("") : Prompts.query(""), text,
        ]
        .map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        lastEncodingTimings = ["model_load": cold ? (ready - loading) * 1000 : 0, "encode": 0, "cache_hit": false]
        if let cached = vectorCache[key] {
            lastEncodingTimings["cache_hit"] = true
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return cached
        }
        do {
            guard let values = try encoder.embedTexts([code ? Prompts.codeQuery(text) : Prompts.query(text)]).first,
                values.count == encoder.info.dim, values.allSatisfy({ $0.isFinite }),
                abs(values.reduce(0.0) { $0 + Double($1) * Double($1) } - 1) < 0.005
            else { throw CLIError("the accelerator returned an invalid query vector") }
            recordInference(encoder)
            lastEncodingTimings["encode"] = (Self.now - ready) * 1000
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > 256 { vectorCache.removeValue(forKey: cacheOrder.removeFirst()) }
            vectorCache[key] = values
            return values
        } catch {
            FileHandle.standardError.write(Data("encoder: \(error)\n".utf8))
            failEncoder(error)
            return nil
        }
    }

    private func runningEncoder() -> (any Embedder)? {
        if let encoder { return encoder }
        guard encoderState != "unavailable" else { return nil }
        encoderState = "starting"
        do {
            let started = Self.now
            let backend = try Acceleration.selected()
            var config =
                try WorkerConfig.fromEnvironment()
                ?? WorkerConfig.helper(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
            if backend != .openvinoNPU { config.arguments += ["--index", baseDirectory.path] }
            config.environment["DIGUP_INFERENCE_PRIORITY"]="foreground"
            config.onInferenceActivity={ [self] activity in
                guard let data=try? JSONEncoder().encode(activity),let fields=try? JSONSerialization.jsonObject(with:data) else{return}
                write(["event":"inference_activity","activity":fields])
            }
            config.log = log
            config.qos = .userInitiated
            config.startupTimeout = 180
            config.requestTimeout = 60
            config.onStart = { [self] process in
                stateLock.withLock {
                    loadingProcess = process
                    if stopping { EmbeddingWorker.interrupt(process) }
                }
                write([
                    "event": "encoder", "state": "starting", "process_id": process.processIdentifier,
                    "inference_verified": false,
                ])
            }
            let worker = try EmbeddingWorker(config, textOnly: true)
            guard worker.info.executionPolicy == "accelerator-only", worker.info.dim == 768,
                backend != .openvinoNPU || worker.info.device?.hasPrefix("NPU") == true
            else {
                worker.close()
                throw CLIError("Query worker did not verify the selected accelerator-only execution")
            }
            stateLock.withLock {
                activeWorker = worker
                loadingProcess = nil
            }
            encoder = worker
            encoderState = "ready"
            encoderError = nil
            var receipt = worker.info.fields
            receipt["event"] = "encoder"
            receipt["state"] = "ready"
            receipt["source"] = worker.info.vectorSource
            receipt["inference_verified"] = false
            receipt["seconds"] = ((Self.now - started) * 100).rounded() / 100
            write(receipt)
            return worker
        } catch {
            stateLock.withLock {
                if let loadingProcess { EmbeddingWorker.interrupt(loadingProcess) }
                loadingProcess = nil
            }
            failEncoder(error)
            return nil
        }
    }

    private func stopEncoder() {
        encoder?.close()
        encoder = nil
        stateLock.withLock { activeWorker = nil }
        encoderPerformedInference = false
        vectorCache.removeAll()
        cacheOrder.removeAll()
        if encoderState != "unavailable" { encoderState = "stopped" }
    }

    private func recordInference(_ worker: any Embedder) {
        guard !encoderPerformedInference else { return }
        encoderPerformedInference = true
        var receipt = worker.info.fields
        receipt["event"] = "encoder"
        receipt["state"] = "ready"
        receipt["inference_verified"] = true
        write(receipt)
    }

    private func failEncoder(_ error: Error) {
        stopEncoder()
        encoderState = "unavailable"
        let reason =
            (try? Acceleration.selected()) == .nvidiaCUDA
            ? Acceleration.cudaFailure(diagnostic: "\(error)", fallback: "CUDA query worker stopped: \(error)")
            : "\(error)"
        encoderError = String(reason.prefix(500))
        write(["event": "encoder", "state": "unavailable", "error": encoderError ?? "Inference failed"])
    }

    private func idleWatch() {
        while !stateLock.withLock({ stopping }) {
            Thread.sleep(forTimeInterval: 1)
            inference.submit(key: "idle-check", foreground: false) { [self] in
                guard encoder != nil || stateLock.withLock({ snapshotBytes > 0 }), Self.now - lastQuery > idleSeconds
                else { return }
                stopEncoder()
                retrieval.submit(key: "idle-release", foreground: false) { [self] in
                    semanticSearcher = nil
                    semanticCodeSearcher = nil
                    semanticStore = nil
                    semanticCodeStore = nil
                    stateLock.withLock { snapshotBytes = 0 }
                }
                if encoderState != "unavailable" { write(["event": "encoder", "state": "stopped", "reason": "idle"]) }
            }
        }
    }
}

/// A hit as JSON: what `digup search --json` prints, plus what a shell's preview needs.
func hitFields(_ hit: SearchHit) -> [String: Any] {
    var row: [String: Any] = [
        "path": hit.path, "kind": hit.kind.rawValue, "segment": hit.segment.rawValue,
        "segment_id": hit.segmentID, "score": hit.score, "modified": hit.modified,
        "size": hit.size, "info": hit.info,
    ]
    if let z = hit.z { row["z"] = z }
    if let cosine = hit.cosine { row["cosine"] = cosine }
    if let rank = hit.keywordRank { row["keyword_rank"] = rank }
    if let loc = hit.loc { row["loc"] = loc }
    if let end = hit.locEnd { row["loc_end"] = end }
    if let focus = hit.focus { row["focus"] = focus }
    if let excerpt = hit.excerpt { row["excerpt"] = excerpt }
    return row
}

func searchService(_ args: Arguments) throws -> Int32 {
    let service = try SearchService(
        index: args.indexFolder, baseIndex: args.baseIndexFolder,
        roots: args.positional.map { Arguments.folderURL($0).path },
        skipped: (args.lists["--exclude"] ?? []).map { Arguments.folderURL($0).path },
        types: IndexOptions.extensions((args.lists["--exclude-ext"] ?? []).joined(separator: ",")),
        codeRoots: (args.lists["--code-root"] ?? []).map { Arguments.folderURL($0).path },
        codeSkipped: (args.lists["--code-exclude"] ?? []).map { Arguments.folderURL($0).path },
        idleSeconds: args.values["--encoder-idle"].flatMap(Double.init) ?? 300)
    emit(["event": "ready", "index": args.indexFolder.path])
    return service.serve()
}
