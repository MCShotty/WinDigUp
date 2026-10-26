import Foundation

public enum IndexerError: Error, CustomStringConvertible {
    case fingerprintMismatch(index: String, now: String)

    public var description: String {
        switch self {
        case .fingerprintMismatch(let index, let now):
            "this index was built with different settings or model:\n  index: \(index)\n  now:   \(now)\n"
                + "re-run with --reindex (vectors from different settings can't be compared)"
        }
    }
}

/// Keeps the index in step with the chosen folders, then extracts and embeds whatever is pending.
///
/// Bounded preparation and inference feed one ordered database writer.
public final class Indexer {
    public struct SyncSummary: Sendable {
        public var added = 0, changed = 0, moved = 0, removed = 0, unchanged = 0
        public var crawl: CrawlReport
        /// Files this sync queued for embedding (new or changed), so a watcher can index exactly those first.
        public var queued: [Int64] = []
    }

    public struct Event: Sendable {
        public let done: Int
        public let total: Int
        public let path: String
        public let kind: FileKind
        public let state: String
        public let seconds: Double
        public let note: String?
        public let fileID: Int64
    }

    let store: IndexStore
    let options: IndexOptions
    private let makeEmbedder: () throws -> any Embedder
    private var worker: (any Embedder)?
    private var replay: ComputedEmbedding?
    public private(set) var lastPipeline: IndexPipelineSnapshot?
    private let scratch: URL

    /// When set, an index built with another model or other settings is emptied and embedded again (the app: a new
    /// version may bring a new model), and this hears about it. When nil, indexing stops with `fingerprintMismatch`.
    public var resetOnModelChange: ((_ indexed: String, _ now: String) -> Void)?

    /// The vector source of the embedders `makeEmbedder` makes, when it's known without starting one (llama.cpp's is):
    /// then `checkModel()` can notice a new model before anything needs embedding.
    public var embedderSource: String?
    /// The index folder, where what indexing costs on this Mac is kept (`MeasuredCosts`) for estimates. Unset: nothing
    /// is kept.
    public var costsFolder: URL?
    private var measured = MeasuredCosts()

    public init(store: IndexStore, options: IndexOptions, makeEmbedder: @escaping () throws -> any Embedder) throws {
        self.store = store
        self.options = options
        self.makeEmbedder = makeEmbedder
        // One folder per process ($TMPDIR/DigUp-<pid>, which the helper clears up after a process that died), and one
        // in it per indexer: the helper runs two (the main index and the code index), and each clears its own away.
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigUp-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        worker?.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Frees the embedding model (about 1 GB) until the next file needs it.
    public func closeWorker() {
        worker?.close()
        worker = nil
    }

    /// Stops the worker and removes the scratch folder, for a process that's about to exit (deinit won't run then).
    public func finish() {
        closeWorker()
        try? FileManager.default.removeItem(at: scratch)
    }

    public var workerIsRunning: Bool { worker != nil }

    // MARK: Sync

    /// Crawls `roots` and reconciles the index: new files are queued, changed ones re-queued, moved ones re-pathed
    /// (no re-embedding), and files that are gone or newly excluded are removed.
    public func sync(_ roots: [URL], onProgress: (CrawlProgress) -> Void = { _ in }) throws -> SyncSummary {
        let crawl = Crawler.crawl(roots, options: options, onProgress: onProgress)
        onProgress(CrawlProgress(stage: "reconciling", root: "", path: store.file.path,
                                visited: crawl.visited, candidates: crawl.candidates.count))
        let existing = try store.files(under: roots.map { $0.standardizedFileURL.path })
        var byPath: [String: FileRecord] = [:]
        var byInode: [String: FileRecord] = [:]
        for file in existing {
            byPath[file.path] = file
            // Windows can return metadata without a file ID (a provider may reject opening its handle).
            // Unknown identities must never turn unrelated files into renames.
            if file.inode != 0 { byInode["\(file.device):\(file.inode)"] = file }
        }
        let seen = Set(crawl.candidates.map(\.path))
        var movedFrom = Set<String>()
        var summary = SyncSummary(crawl: crawl)
        try store.db.transaction {
            for file in crawl.candidates {
                if let row = byPath[file.path] {
                    if row.size != file.size || abs(row.mtime - file.mtime) > 0.001 || row.kind != file.kind {
                        try store.requeue(row.id, as: file)
                        summary.changed += 1
                        summary.queued.append(row.id)
                    } else {
                        summary.unchanged += 1
                    }
                } else if let row = byInode["\(file.device):\(file.inode)"], !seen.contains(row.path),
                          !movedFrom.contains(row.path), row.kind == file.kind,
                          row.size == file.size, abs(row.mtime - file.mtime) < 0.001 {
                    try store.move(row.id, to: file.path)
                    movedFrom.insert(row.path)
                    summary.moved += 1
                } else {
                    summary.queued.append(try store.insert(file))
                    summary.added += 1
                }
            }
            // Failed listings and roots that disappeared mid-crawl are incomplete evidence, not deletions.
            let unavailable = Array(crawl.unreadable) + roots.map { $0.standardizedFileURL.path }
                .filter { !FileManager.default.fileExists(atPath: $0) }
            for row in existing where !seen.contains(row.path) && !movedFrom.contains(row.path)
                && !unavailable.contains(where: { row.path == $0 || FolderSelection.isInside(row.path, $0) }) {
                try store.delete(row.id)
                summary.removed += 1
            }
        }
        return summary
    }

    public var scanOptions: IndexOptions { options }

    public func beginScan(_ roots: [URL]) throws -> IndexScanSession {
        try IndexScanSession(store:store,roots:roots)
    }

    // MARK: Run

    /// Processes pending files, screenshots first, newest first (`only`: just these files). Long PDFs and documents get
    /// their first step (`IndexOptions.pdfStep` pages, `docStep` chunks) and stay `partial` for `finishLongFiles`.
    /// Per-file problems are recorded on the file; a dead worker or a settings mismatch stops the run (pending files stay
    /// pending, so the next run resumes). `shouldStop` is asked between batches: pausing, or new files that should go
    /// first.
    public struct ScheduleSource {
        public let indexer: Indexer
        public let priorityIDs: Set<Int64>
        public let includePending: Bool
        public let limit: Int?
        public init(indexer: Indexer, priorityIDs: Set<Int64> = [], includePending: Bool = true, limit: Int? = nil) {
            self.indexer = indexer
            self.priorityIDs = priorityIDs
            self.includePending = includePending
            self.limit = limit
        }
    }

    @discardableResult
    public func run(limit: Int? = nil, only ids: Set<Int64>? = nil, shouldStop: () -> Bool = { false },
                    onEvent: (Event) -> Void = { _ in }) throws -> [String: Int] {
        try Indexer.runScheduled([ScheduleSource(indexer: self, priorityIDs: ids ?? [],
            includePending: ids == nil, limit: limit)], shouldStop: shouldStop,
            onEvent: { _, _, event in onEvent(event) }).first ?? [:]
    }

    /// One owner pages both indexes; switching ready sources never drains inference.
    @discardableResult
    public static func runScheduled(_ sources: [ScheduleSource], shouldStop: () -> Bool = { false },
        onEvent: (Int, Bool, Event) -> Void = { _, _, _ in },
        onSnapshot: (IndexPipelineSnapshot) -> Void = { _ in },
        onRemaining: (Int, Set<Int64>) -> Void = { _, _ in },
        onVerified: (WorkerInfo) -> Void = { _ in },
        admit: @escaping () throws -> [[Int64]] = { [] },
        inputComplete: @escaping () -> Bool = { true },
        priority: @escaping () -> (Int,String)? = { nil }) throws -> [[String: Int]] {
        guard !sources.isEmpty else { return [] }
        guard Set(sources.map { $0.indexer.store.file.standardizedFileURL.path }).count == sources.count else {
            throw Database.Failure(message: "Each scheduled index must have one database owner.")
        }
        var queues: [PendingFileQueue] = []
        defer { for queue in queues { queue.close() } }
        for source in sources {
            source.indexer.lastPipeline = nil
            queues.append(try source.indexer.store.pendingQueue(priorityIDs: source.priorityIDs,
                includePending: source.includePending, limit: source.limit))
        }
        var lastSource = sources.count - 1
        var consecutive = 0
        var states = Array(repeating: [String: Int](), count: sources.count)
        var done = Array(repeating: 0, count: sources.count)
        func nextJob() throws -> Job? {
            if let (source,path)=priority(),queues.indices.contains(source) {queues[source].prioritize(path)}
            let updates = try admit()
            for index in queues.indices where index < updates.count { try queues[index].append(updates[index]) }
            var priorities: [Int: Int] = [:]
            for index in queues.indices {
                if let first = try queues[index].peek() { priorities[index] = first.priority }
            }
            guard let best = priorities.values.min() else { return nil }
            let order = (1...sources.count).map { (lastSource + $0) % sources.count }
            let preferred = order.first(where: { priorities[$0] == best })
            let fair = consecutive>=8 ? order.first(where:{$0 != lastSource && priorities[$0] != nil}) : nil
            guard let selected=fair ?? preferred,let batch=try queues[selected].takeBatch() else {return nil}
            consecutive = selected==lastSource ? consecutive+1 : 1
            lastSource = selected
            return Job(files: batch.files, source: selected, priority: batch.priority,
                       options: sources[selected].indexer.options)
        }
        try processOwned(sources.map(\.indexer), nextJob: nextJob, inputComplete: inputComplete, shouldStop: shouldStop,
            decorate: { snapshot in for queue in queues { queue.decorate(&snapshot) } },
            onSnapshot: onSnapshot, onVerified: onVerified, committed: { _, job, results, seconds in
                let source = job.source
                for (offset, file) in job.files.enumerated() {
                    let (state, note) = results[offset]
                    states[source][state, default: 0] += 1
                    onEvent(source, job.priority == 0, Event(done: done[source] + offset + 1,
                        total: queues[source].total, path: file.path, kind: file.kind,
                        state: state, seconds: seconds, note: note, fileID: file.id))
                }
                done[source] += job.files.count
            })
        for index in queues.indices { onRemaining(index, try queues[index].remainingPriorityIDs()) }
        return states
    }

    /// One step of the later pass: how far it has got (`done` of the `total` pages and chunks it set out to read, in
    /// `files` files), and the file it just read more of.
    public struct Step: Sendable {
        public let done: Int
        public let total: Int
        public let files: Int        // long files not finished yet, this one included until its last step
        public let path: String
        public let kind: FileKind
        public let state: String     // "partial" until the file's last step, then "done"
        public let seconds: Double
        public let note: String?
    }

    /// The later pass: reads the rest of long PDFs and documents (`partial` after their first step), in indexing order,
    /// a step at a time. Each step is saved as one transaction, so stopping between steps (pausing, new files going
    /// first) loses nothing, and the next pass goes on from there. It runs once nothing is pending: a book's last
    /// pages matter less than everything else's first ones, and they take a while (0.04–0.2 s a page, 2026-10-09).
    @discardableResult
    public func finishLongFiles(shouldStop: () -> Bool = { false }, onStep: (Step) -> Void = { _ in }) throws
        -> [String: Int] {
        lastPipeline = nil
        let queue = try store.pendingQueue(state: "partial")
        defer { queue.close() }
        let total = try queue.longFileUnits()
        var files = queue.total
        var states: [String: Int] = [:]
        var finishedFile: Int64?
        var current: FileRecord?
        var next = 0
        var end = 0
        var through = 0
        func nextJob() throws -> Job? {
            while true {
                if current?.id == finishedFile { next = end }
                if let file = current, next < end {
                    let size = file.kind == .pdf ? options.pdfStep : options.docStep
                    let range = next..<min(next + size, end)
                    next = range.upperBound
                    through += range.count
                    return Job(files: [file], step: range, options: options, through: through)
                }
                guard let entry = try queue.take() else { return nil }
                let file = entry.file
                let info = try store.info(of: file.id)
                next = try info["read_to"].flatMap(Int.init) ?? store.lastPlace(of: file.id) ?? 0
                end = max(info["read_end"].flatMap(Int.init) ?? 0, next + 1)
                current = file
            }
        }
        try Indexer.processOwned([self], nextJob: nextJob, shouldStop: shouldStop,
            decorate: { queue.decorate(&$0) }, committed: { _, job, results, seconds in
                let file = job.files[0]
                let (state, note) = results[0]
                if state != "partial" {
                    finishedFile = file.id
                    states[state, default: 0] += 1
                    files -= 1
                }
                onStep(Step(done: job.through, total: total, files: files, path: file.path, kind: file.kind,
                            state: state, seconds: seconds, note: note))
            }, skip: { $0.files[0].id == finishedFile })
        return states
    }

    private static func processOwned(_ indexers: [Indexer], nextJob: @escaping () throws -> Job?,
        inputComplete: @escaping () -> Bool = { true }, shouldStop: () -> Bool, decorate: (inout IndexPipelineSnapshot) -> Void = { _ in },
        onSnapshot: (IndexPipelineSnapshot) -> Void = { _ in },
        onVerified: (WorkerInfo) -> Void = { _ in },
        committed: (Int, Job, [(String, String?)], Double) -> Void,
        skip: (Job) -> Bool = { _ in false }) throws {
        let folders = indexers.map { $0.scratch.appendingPathComponent(UUID().uuidString) }
        let options = indexers.map(\.options)
        // Concrete type references avoid Swift 6.4's dynamic-Self closure-specialization crash.
        let pipeline = IndexPipeline<Job, Prepared, ComputedEmbedding?>(nextInput: nextJob, inputComplete: inputComplete,
            source: { String($0.source) }, sizes: { $0.footprint },
            prepare: { index, job in
                autoreleasepool {
                    Indexer.prepare(job, options: job.options ?? options[job.source],
                                 into: folders[job.source].appendingPathComponent("batch-\(index)"))
                }
            }, cleanup: { prepared in
                try? FileManager.default.removeItem(at: prepared.folder)
            })
        var modelLoadMs = 0.0
        var notificationMs = 0.0
        var lastNotification = 0.0
        var verified = false
        func snapshot() -> IndexPipelineSnapshot {
            var value = pipeline.snapshot(modelLoadMs: modelLoadMs)
            value.notificationMs = notificationMs
            decorate(&value)
            return value
        }
        func progress(force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastNotification >= 1 else { return }
            lastNotification = now
            let start = ProcessInfo.processInfo.systemUptime
            onSnapshot(snapshot())
            notificationMs += (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        defer {
            pipeline.close()
            let value = snapshot()
            for index in indexers.indices {
                var own = value
                own.source = String(index)
                indexers[index].lastPipeline = own
                try? FileManager.default.removeItem(at: folders[index])
                if let costsFolder = indexers[index].costsFolder, !indexers[index].measured.tallies.isEmpty {
                    MeasuredCosts.merge(indexers[index].measured, into: costsFolder)
                    indexers[index].measured = MeasuredCosts()
                }
            }
            progress(force: true)
        }

        func publish(_ item: IndexPipeline<Job, Prepared, ComputedEmbedding?>.Item,
                     computed: ComputedEmbedding?, inferenceMs: Double) throws {
            let start = ProcessInfo.processInfo.systemUptime
            var didCommit = false
            defer {
                if shouldStop() { pipeline.stop() }
                pipeline.release(item, commitMs: (ProcessInfo.processInfo.systemUptime - start) * 1000, committed: didCommit)
            }
            guard !skip(item.input) else { return }
            let owner = indexers[item.input.source]
            if !verified, let computed, computed.hasVectors, computed.info.executionPolicy == "accelerator-only",
               let device = computed.info.device, !device.isEmpty {
                verified = true
                onVerified(computed.info)
            }
            let results: [(String, String?)]
            do { results = try owner.publish(item.value, computed: computed) }
            catch { pipeline.fail(error); throw error }
            didCommit = true
            let seconds = (item.preparationMs + inferenceMs) / 1000
            owner.measure(item.value, seconds: seconds)
            let notificationStart = ProcessInfo.processInfo.systemUptime
            committed(item.index, item.input, results, seconds / Double(item.input.files.count))
            notificationMs += (ProcessInfo.processInfo.systemUptime - notificationStart) * 1000
        }

        do {
            while let item = pipeline.nextPrepared(shouldStop: shouldStop, canStartWith: {
                Indexer.embeddingCalls($0, options: $0.options).contains(where: { !$0.inputs.isEmpty })
            }, onTick: { progress() }) {
                if skip(item.input) || !Indexer.embeddingCalls(item.value, options: item.value.options).contains(where: { !$0.inputs.isEmpty }) {
                    try publish(item, computed: nil, inferenceMs: 0)
                    continue
                }
                let start = ProcessInfo.processInfo.systemUptime
                let models = try indexers.map { try $0.fullWorker() }
                guard let first = models.first, models.allSatisfy({
                    $0.info.vectorSource == first.info.vectorSource && $0.info.backend == first.info.backend
                        && $0.info.deviceId == first.info.deviceId && $0.info.device == first.info.device
                }) else { throw WorkerError.failed("Scheduled indexes resolved different embedding devices or identities.") }
                modelLoadMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let owners = InferenceOwners(models)
                let width = models.map { ($0 as? any ParallelEmbedding)?.maximumParallelJobs ?? 1 }.min() ?? 1
                pipeline.startInference(parallelism: width) { prepared in
                    let calls = Indexer.embeddingCalls(prepared, options: prepared.options)
                    guard calls.contains(where: { !$0.inputs.isEmpty }) else { return nil }
                    return try ComputedEmbedding(calls: calls, worker: owners.models[prepared.source])
                }
                while let result = pipeline.next(shouldStop: shouldStop, onTick: { progress() }) {
                    try publish(result.item, computed: result.result.get(), inferenceMs: result.inferenceMs)
                }
                break
            }
            try pipeline.throwIfFailed()
        } catch {
            pipeline.fail(error)
            throw error
        }
    }

    private func publish(_ prepared: Prepared, computed: ComputedEmbedding?) throws -> [(String, String?)] {
        let changed = prepared.batch.contains { file in
            guard let current = FileSystem.info(of: file.path), current.isRegular else { return true }
            return current.size != file.size || abs(current.mtime - file.mtime) > 0.001 ||
                file.inode != 0 && current.inode != 0 && (current.inode != file.inode || current.device != file.device)
        }
        replay = computed
        defer { replay = nil }
        return try store.db.transaction {
            if let computed {
                let expected = "\(computed.info.vectorSource) | \(options.fingerprint)"
                let actual = try store.meta("fingerprint") ?? ""
                if actual != expected { throw IndexerError.fingerprintMismatch(index: actual, now: expected) }
            }
            for file in prepared.batch {
                var matches = false
                try store.db.query("SELECT path,size,mtime,inode,device FROM files WHERE id=?", [.int(file.id)]) { row in
                    matches = row.text(0) == file.path && row.int(1) == file.size &&
                        abs(row.double(2) - file.mtime) < 0.001 &&
                        UInt64(bitPattern: row.int(3)) == file.inode && UInt64(bitPattern: row.int(4)) == file.device
                }
                if !matches { return prepared.batch.map { _ in ("pending", "source_changed") } }
            }
            if changed {
                for file in prepared.batch { try store.requeue(file.id) }
                return prepared.batch.map { _ in ("pending", "source_changed") }
            }
            return try autoreleasepool { try commit(prepared) }
        }
    }

    private final class InferenceOwners: @unchecked Sendable {
        let models: [any Embedder]
        init(_ models: [any Embedder]) { self.models = models }
    }

    private static func embeddingCalls(_ prepared: Prepared, options: IndexOptions) -> [EmbeddingCall] {
        let file=prepared.batch[0]
        let title=URL(fileURLWithPath:file.path).deletingPathExtension().lastPathComponent
        switch prepared.payload {
        case .nothing:return []
        case .images(let screenshot,let ready):
            return [EmbeddingCall(kind:.image,inputs:ready.map(\.image.path),
                budget:screenshot ? options.screenshotBudget : options.photoBudget)]
        case .pdf(let pages,_,_,let documentTitle):
            let title=documentTitle ?? title
            return [
                EmbeddingCall(kind:.text,inputs:pages.filter{$0.imagePath==nil && SearchText.hasWords($0.text)}.map{Prompts.document(title:title,text:String($0.text.prefix(4000)))}),
                EmbeddingCall(kind:.image,inputs:pages.compactMap(\.imagePath),budget:options.pageBudget),
                EmbeddingCall(kind:.text,inputs:pages.compactMap(\.garbled).map{Prompts.document(title:title,text:String($0.prefix(4000)))})
            ]
        case .doc(let chunks,_,_,_):
            return [EmbeddingCall(kind:.text,inputs:chunks.filter(SearchText.hasWords).map{Prompts.document(title:title,text:$0)})]
        case .code(let code):
            return [EmbeddingCall(kind:.text,inputs:code.pieces.filter{SearchText.hasWords($0.text)}.map{Prompts.document(title:code.title,text:$0.text)})]
        case .audio(let pieces,_):return [EmbeddingCall(kind:.audio,inputs:pieces.map(\.path))]
        case .video(let frames,let sound,_):
            return [EmbeddingCall(kind:.image,inputs:frames.map(\.path),budget:options.frameBudget),
                EmbeddingCall(kind:.audio,inputs:sound.map(\.path))]
        }
    }

    /// What a job read and how long it took (its reading and its model's work, which overlap), for `MeasuredCosts`.
    private func measure(_ prepared: Prepared, seconds: Double) {
        switch prepared.payload {
        case .images(let screenshot, let ready):
            measured.add(screenshot ? "screenshot" : "image", units: Double(ready.count), seconds: seconds)
        case .pdf(let pages, _, _, _): measured.add("pdfPage", units: Double(pages.count), seconds: seconds)
        case .doc(let chunks, _, _, _):
            // Chunks with a vector: a data dump's go to keyword search only and take next to nothing, which isn't
            // what a chunk of prose costs (the estimate can't tell them apart from a file's size).
            let worded = chunks.filter(SearchText.hasWords).count
            if worded > 0 { measured.add("docChunk", units: Double(worded), seconds: seconds) }
        case .audio(_, let duration): measured.add("audioSecond", units: duration, seconds: seconds)
        case .video(_, _, let duration): measured.add("videoSecond", units: duration, seconds: seconds)
        case .code(let file): measured.add("codeStretch", units: Double(file.pieces.count), seconds: seconds)
        case .nothing: break
        }
    }

    /// Files read and embedded together (images 8 at a time, other files one by one), or one step of a long file
    /// (`step`: the pages of a PDF or the chunks of a document to read, from 0). The first step comes with the file.
    struct Job: Sendable {
        let files: [FileRecord]
        var step: Range<Int>?
        var source = 0
        var priority = 1
        var options: IndexOptions?
        var through = 0
    }

    /// Images and screenshots go to the model 8 at a time; other files one by one.
    static func batches(_ queue: [FileRecord]) -> [[FileRecord]] {
        var batches: [[FileRecord]] = []
        var index = 0
        while index < queue.count {
            var batch = [queue[index]]
            if batch[0].kind == .image || batch[0].kind == .screenshot {
                while index + batch.count < queue.count, batch.count < 8,
                      queue[index + batch.count].kind == batch[0].kind {
                    batch.append(queue[index + batch.count])
                }
            }
            batches.append(batch)
            index += batch.count
        }
        return batches
    }

    /// Compares the index with the current model and settings (`embedderSource`), without starting the model; a
    /// change empties the index (see `resetOnModelChange`) or throws `fingerprintMismatch`. Without a known source the
    /// check waits for the first file to embed.
    public func checkModel() throws {
        guard let embedderSource else { return }
        try adopt("\(embedderSource) | \(options.fingerprint)")
    }

    private func adopt(_ fingerprint: String) throws {
        guard let indexed = try store.meta("fingerprint"), indexed != fingerprint else { return }
        guard let resetOnModelChange else { throw IndexerError.fingerprintMismatch(index: indexed, now: fingerprint) }
        // Everything is queued again: a run that's under way goes on with its batch, and later runs take the rest.
        try store.resetAll()
        resetOnModelChange(indexed, fingerprint)
    }

    private func fullWorker() throws -> any Embedder {
        if let replay { return replay }
        if let worker { return worker }
        let started = try makeEmbedder()
        let fingerprint = "\(started.info.vectorSource) | \(options.fingerprint)"
        do {
            try adopt(fingerprint)
        } catch {
            started.close()
            throw error
        }
        try store.setMeta("fingerprint", fingerprint)
        try store.setMeta("vector_source", started.info.vectorSource)
        worker = started
        return started
    }

    // MARK: Prepare (any thread: files only, no database, no model)

    /// A job read from disk and decoded, ready for the model. Its scratch files live in `folder`.
    struct Prepared: Sendable {
        let batch: [FileRecord]
        let step: Range<Int>?                // a long file's later step (`Job.step`)
        let folder: URL
        var outcomes: [Int: Outcome] = [:]   // files already settled (skipped or failed while reading)
        var payload = Payload.nothing
        let source: Int
        let options: IndexOptions

        var footprint: (memory: Int, scratch: Int) {
            var memory = 0
            var paths: [String] = []
            switch payload {
            case .nothing: break
            case .images(_, let images): paths = images.map(\.image.path); memory = images.reduce(0) { $0 + $1.ocr.utf8.count }
            case .pdf(let pages, _, _, _):
                memory = pages.reduce(0) { $0 + $1.text.utf8.count + ($1.garbled?.utf8.count ?? 0) }
                paths = pages.compactMap(\.imagePath)
            case .doc(let chunks, _, _, _): memory = chunks.reduce(0) { $0 + $1.utf8.count }
            case .code(let code): memory = code.pieces.reduce(0) { $0 + $1.text.utf8.count }
            case .audio(let pieces, _): paths = pieces.map(\.path)
            case .video(let frames, let sound, _): paths = frames.map(\.path) + sound.map(\.path)
            }
            let scratch = Set(paths).reduce(0) { total, path in
                total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0)
            }
            return (memory + paths.reduce(0) { $0 + $1.utf8.count }, scratch)
        }
    }

    struct Outcome: Sendable {
        let state: String
        let detail: String?
    }

    enum Payload: Sendable {
        case nothing
        case images(screenshot: Bool, ready: [ReadyImage])
        /// `read`: the pages read (from 0) of the PDF's `total`.
        case pdf(pages: [PDFExtractor.Page], read: Range<Int>, total: Int, title: String?)
        /// `chunks`: the ones in `read` (from 0) of the document's `total` (counted up to `IndexOptions.maxChunks` + 1).
        case doc(chunks: [String], read: Range<Int>, total: Int, characters: Int)
        case audio(pieces: [MediaPiece], duration: Double)
        case video(frames: [MediaPiece], sound: [MediaPiece], duration: Double)
        case code(CodeExtractor.File)
    }

    struct ReadyImage: Sendable {
        let slot: Int
        let image: ImageExtractor.Prepared
        let ocr: String
    }

    /// The oldest active extraction remains visible when another preparation finishes.
    public static var nowReading: (path: String, since: Date)? {
        readingLock.withLock { reading.values.min { $0.since < $1.since } }
    }
    nonisolated(unsafe) private static var reading: [String: (path: String, since: Date)] = [:]
    private static let readingLock = NSLock()

    static var activeReadPaths: Set<String> { readingLock.withLock { Set(reading.values.map(\.path)) } }

    static func startReading(_ path: String, token: String) {
        readingLock.withLock { reading[token] = (path, Date()) }
    }

    static func endReading(token: String) {
        _ = readingLock.withLock { reading.removeValue(forKey: token) }
    }

    static func prepare(_ job: Job, options: IndexOptions, into folder: URL) -> Prepared {
        let batch = job.files
        var prepared = Prepared(batch: batch, step: job.step, folder: folder, source: job.source, options: options)
        let url = URL(fileURLWithPath: batch[0].path)
        startReading(batch[0].path, token: folder.path)
        defer { endReading(token: folder.path) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            switch batch[0].kind {
            case .image, .screenshot:
                let screenshot = batch[0].kind == .screenshot
                var ready: [ReadyImage] = []
                for (slot, file) in batch.enumerated() {
                    let url = URL(fileURLWithPath: file.path)
                    startReading(file.path, token: folder.path)
                    do {
                        let image = try ImageExtractor.prepare(url, maxPixel: screenshot ? 1536 : 1024,
                                                               minSide: options.minImageSide, to: folder,
                                                               png: screenshot)
                        let ocr = screenshot ? OCR.text(ofImageAt: url) : ""
                        ready.append(ReadyImage(slot: slot, image: image, ocr: ocr))
                    } catch let error as ExtractError {
                        if case .tooSmall = error {
                            prepared.outcomes[slot] = Outcome(state: "skipped", detail: "\(error)")
                        } else {
                            prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
                        }
                    }
                }
                prepared.payload = .images(screenshot: screenshot, ready: ready)
            case .pdf:
                // Long PDFs (books) get their first pages now and the rest after everything else.
                var wanted = 0..<0
                let read = try PDFExtractor.pages(of: url, range: { total in
                    wanted = (job.step ?? (total > options.bigPDFPages ? 0..<options.pdfStep : 0..<options.maxPages))
                        .clamped(to: 0..<min(total, options.maxPages))
                    return wanted
                }, minText: options.minPageText, renderPixels: 1400, to: folder)
                prepared.payload = .pdf(pages: read.pages, read: wanted, total: read.total, title: read.title)
            case .doc:
                // The chunks are cut the same way every time, so a later step goes on where the last one stopped.
                let text = try DocExtractor.text(of: url)
                let chunks = DocExtractor.chunks(text, limit: options.maxChunks + 1)
                let read = (job.step ?? 0..<options.docStep).clamped(to: 0..<min(chunks.count, options.maxChunks))
                prepared.payload = .doc(chunks: Array(chunks[read]), read: read, total: chunks.count,
                                        characters: text.count)
            case .audio:
                let (window, hop) = (options.audioWindow, options.audioHop)
                let (pieces, duration) = try runBlocking {
                    try await AudioExtractor.windows(of: url, window: window, hop: hop, to: folder)
                }
                prepared.payload = .audio(pieces: pieces, duration: duration)
            case .video:
                let (interval, window, hop) = (options.frameInterval, options.audioWindow, options.audioHop)
                let (frames, duration, hasAudio) = try runBlocking {
                    try await VideoExtractor.keyframes(of: url, every: interval, maxPixel: 1024, to: folder)
                }
                let sound = hasAudio
                    ? try runBlocking { try await AudioExtractor.windows(of: url, window: window, hop: hop, to: folder) }
                        .pieces
                    : []
                prepared.payload = .video(frames: frames, sound: sound, duration: duration)
            case .code:
                prepared.payload = .code(try CodeExtractor.read(url, options: options))
            }
        } catch let error as ExtractError {
            if case .leftOut = error {
                prepared.outcomes[0] = Outcome(state: "skipped", detail: "\(error)")
            } else {
                for slot in batch.indices where prepared.outcomes[slot] == nil {
                    prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
                }
            }
            prepared.payload = .nothing
        } catch {
            for slot in batch.indices where prepared.outcomes[slot] == nil {
                prepared.outcomes[slot] = Outcome(state: "failed", detail: "\(error)")
            }
            prepared.payload = .nothing
        }
        return prepared
    }

    // Commit owns the database; its embedder replays prepared results.

    private func commit(_ prepared: Prepared) throws -> [(String, String?)] {
        let batch = prepared.batch
        let later = prepared.step != nil
        if let step = prepared.step, let outcome = prepared.outcomes[0] {
            return [try stopReading(batch[0], at: step.lowerBound, because: outcome.detail ?? outcome.state)]
        }
        var results = [(String, String?)](repeating: ("failed", nil), count: batch.count)
        for (slot, outcome) in prepared.outcomes {
            try store.finish(batch[slot].id, state: outcome.state, detail: outcome.detail)
            results[slot] = (outcome.state, outcome.detail)
        }
        do {
            switch prepared.payload {
            case .nothing:
                break
            case .images(let screenshot, let ready):
                try images(batch, screenshot: screenshot, ready: ready, results: &results)
            case .pdf(let pages, let read, let total, let title):
                results[0] = try pdf(batch[0], pages: pages, read: read, total: total, title: title, later: later)
            case .doc(let chunks, let read, let total, let characters):
                results[0] = try doc(batch[0], chunks: chunks, read: read, total: total, characters: characters,
                                     later: later)
            case .audio(let pieces, let duration):
                results[0] = try audio(batch[0], pieces: pieces, duration: duration)
            case .video(let frames, let sound, let duration):
                results[0] = try video(batch[0], frames: frames, sound: sound, duration: duration)
            case .code(let code):
                results[0] = try self.code(batch[0], code)
            }
        } catch let error as WorkerError {
            throw error
        } catch let error as IndexerError {
            throw error
        } catch {
            if let step = prepared.step { return [try stopReading(batch[0], at: step.lowerBound, because: "\(error)")] }
            for (slot, file) in batch.enumerated() where prepared.outcomes[slot] == nil {
                try store.finish(file.id, state: "failed", detail: "\(error)")
                results[slot] = ("failed", "\(error)")
            }
        }
        return results
    }

    /// A long file that can't be read any further: it keeps the pages or chunks read so far, which stay searchable,
    /// and counts as done rather than failed or waiting to be tried again and again.
    private func stopReading(_ file: FileRecord, at place: Int, because problem: String) throws -> (String, String?) {
        var info = try store.info(of: file.id)
        info["read_to"] = nil
        info["read_end"] = nil
        let unit = file.kind == .pdf ? "page" : "chunk"
        try store.finish(file.id, state: "done", detail: "read to \(unit) \(place), not after: \(problem)", info: info)
        return ("done", "stopped before \(unit) \(place + 1): \(problem)")
    }

    private func images(_ batch: [FileRecord], screenshot: Bool, ready: [ReadyImage],
                        results: inout [(String, String?)]) throws {
        guard !ready.isEmpty else { return }
        let worker = try fullWorker()
        let vectors = try worker.embedImages(ready.map(\.image.path),
                                             budget: screenshot ? options.screenshotBudget : options.photoBudget)
        try store.db.transaction {
            for (position, item) in ready.enumerated() {
                let file = batch[item.slot]
                guard let vector = vectors[position].vector else {
                    try store.finish(file.id, state: "failed", detail: vectors[position].error)
                    results[item.slot] = ("failed", vectors[position].error)
                    continue
                }
                try store.addSegment(file: file.id, kind: .image, modality: .image, vector: vector)
                // The words on screen are for keyword search: codes, names and errors typed exactly. Meaning comes from
                // the picture alone; a vector of the words made screenshots outrank better matches (2026-10-08).
                if !item.ocr.isEmpty {
                    try store.addSegment(file: file.id, kind: .ocr, modality: .text, excerpt: excerpt(item.ocr),
                                         text: item.ocr)
                }
                var info = ["width": "\(item.image.width)", "height": "\(item.image.height)"]
                if let taken = item.image.taken { info["taken"] = taken }
                if screenshot { info["ocr_chars"] = "\(item.ocr.count)" }
                try store.finish(file.id, state: "done", info: info)
                results[item.slot] = ("done", screenshot ? "ocr \(item.ocr.count) chars" : nil)
            }
        }
    }

    /// Pages `read` of a PDF (all of a short one, a step of a long one). A long one stays `partial` with `read_to` and
    /// `read_end` (pages, from 0) in its info until its last step.
    private func pdf(_ file: FileRecord, pages: [PDFExtractor.Page], read: Range<Int>, total: Int, title: String?,
                     later: Bool) throws -> (String, String?) {
        let end = min(total, options.maxPages)
        let unread = read.upperBound < end
        guard !pages.isEmpty || later || unread else {
            try store.finish(file.id, state: "skipped", detail: "no pages")
            return ("skipped", "no pages")
        }
        let title = title ?? URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        let textPages = pages.filter { $0.imagePath == nil }
        // A page that's mostly digits (a table, a data listing) gets keyword search only.
        let wordPages = textPages.filter { SearchText.hasWords($0.text) }
        let imagePages = pages.filter { $0.imagePath != nil }
        let garbledPages = pages.filter { $0.garbled != nil }   // rendered too: among `imagePages`
        var textVectors: [Int: [Float]] = [:]   // by page number
        var imageVectors: [Embedding] = []
        var garbledVectors: [[Float]] = []
        if !wordPages.isEmpty || !imagePages.isEmpty {
            let worker = try fullWorker()
            let vectors = try worker.embedTexts(wordPages.map {
                Prompts.document(title: title, text: String($0.text.prefix(4000)))
            })
            textVectors = Dictionary(uniqueKeysWithValues: zip(wordPages.map(\.number), vectors))
            imageVectors = try worker.embedImages(imagePages.compactMap(\.imagePath), budget: options.pageBudget)
            garbledVectors = try worker.embedTexts(garbledPages.map {
                Prompts.document(title: title, text: String($0.garbled!.prefix(4000)))
            })
        }
        try store.db.transaction {
            // Meaning only: the garbled words are never shown or matched against what you type.
            for (page, vector) in zip(garbledPages, garbledVectors) {
                try store.addSegment(file: file.id, kind: .page, modality: .text, loc: Double(page.number), vector: vector)
            }
            for page in textPages {
                try store.addSegment(file: file.id, kind: .page, modality: .text, loc: Double(page.number),
                                     excerpt: excerpt(page.text), text: page.text, vector: textVectors[page.number])
            }
            for (page, embedding) in zip(imagePages, imageVectors) {
                try store.addSegment(file: file.id, kind: .pageImage, modality: .image, loc: Double(page.number),
                                     excerpt: page.text.isEmpty ? nil : excerpt(page.text), text: page.text,
                                     vector: embedding.vector)
            }
            var info = later ? try store.info(of: file.id) : [:]
            info["pages"] = "\(total)"
            info["scanned_pages"] = "\((info["scanned_pages"].flatMap(Int.init) ?? 0) + imagePages.count)"
            info["read_to"] = unread ? "\(read.upperBound)" : nil
            info["read_end"] = unread ? "\(end)" : nil
            let detail = unread ? "read to page \(read.upperBound) of \(total)"
                : end < total ? "the first \(end) of \(total) pages" : nil
            try store.finish(file.id, state: unread ? "partial" : "done", detail: detail, info: info)
        }
        let ocr = pages.filter(\.ocr).count
        let span = later ? "pages \(read.lowerBound + 1)–\(read.upperBound) of \(total)" : "\(pages.count)/\(total) pages"
        return (unread ? "partial" : "done", "\(span), \(imagePages.count) as images" + (ocr > 0 ? ", \(ocr) read by OCR" : ""))
    }

    /// Chunks `read` of a document (all of a short one, a step of a long one), the way `pdf` reads pages.
    private func doc(_ file: FileRecord, chunks: [String], read: Range<Int>, total: Int, characters: Int, later: Bool)
        throws -> (String, String?) {
        guard total > 0 else {
            try store.finish(file.id, state: "skipped", detail: "no text")
            return ("skipped", "no text")
        }
        let title = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
        // Text that's mostly digits (a data dump saved as .txt) gets keyword search only.
        let worded = chunks.indices.filter { SearchText.hasWords(chunks[$0]) }
        let vectors = worded.isEmpty ? [] : try fullWorker().embedTexts(worded.map {
            Prompts.document(title: title, text: chunks[$0])
        })
        let vector = Dictionary(uniqueKeysWithValues: zip(worded, vectors))
        let end = min(total, options.maxChunks)
        let unread = read.upperBound < end
        try store.db.transaction {
            for (offset, chunk) in chunks.enumerated() {
                try store.addSegment(file: file.id, kind: .chunk, modality: .text,
                                     loc: Double(read.lowerBound + offset + 1), excerpt: excerpt(chunk), text: chunk,
                                     vector: vector[offset])
            }
            var info = ["chunks": "\(end)", "chars": "\(characters)"]
            info["read_to"] = unread ? "\(read.upperBound)" : nil
            info["read_end"] = unread ? "\(end)" : nil
            let detail = unread ? "read to chunk \(read.upperBound) of \(end)" : end < total ? "the first \(end) chunks" : nil
            try store.finish(file.id, state: unread ? "partial" : "done", detail: detail, info: info)
        }
        let span = later ? "chunks \(read.lowerBound + 1)–\(read.upperBound) of \(end)"
            : unread ? "\(chunks.count) of \(end) chunks" : "\(chunks.count) chunks"
        return (unread ? "partial" : "done",
                span + (worded.count < chunks.count ? ", \(chunks.count - worded.count) for keywords only" : ""))
    }

    /// A code file's stretches of lines (a notebook's of cells), each embedded with the file's path in its repo as its
    /// title, and kept with its lines for keyword search and for opening at the place.
    private func code(_ file: FileRecord, _ code: CodeExtractor.File) throws -> (String, String?) {
        guard !code.pieces.isEmpty else {
            try store.finish(file.id, state: "skipped", detail: "no code")
            return ("skipped", "no code")
        }
        // Lines that are mostly numbers and symbols (a table of constants) get keyword search only.
        let worded = code.pieces.indices.filter { SearchText.hasWords(code.pieces[$0].text) }
        let vectors = worded.isEmpty ? [] : try fullWorker().embedTexts(worded.map {
            Prompts.document(title: code.title, text: code.pieces[$0].text)
        })
        let vector = Dictionary(uniqueKeysWithValues: zip(worded, vectors))
        try store.db.transaction {
            for (offset, piece) in code.pieces.enumerated() {
                try store.addSegment(file: file.id, kind: code.cells == nil ? .lines : .cells, modality: .text,
                                     loc: Double(piece.first), locEnd: Double(piece.last),
                                     excerpt: CodeExtractor.summary(piece.text), text: piece.text, vector: vector[offset])
            }
            var info = ["lines": "\(code.lines)"]
            info["cells"] = code.cells.map(String.init)
            info["repo"] = code.repo
            try store.finish(file.id, state: "done", info: info)
        }
        return ("done", "\(code.pieces.count) stretches, \(code.cells.map { "\($0) cells" } ?? "\(code.lines) lines")"
                + (worded.count < code.pieces.count ? ", \(code.pieces.count - worded.count) for keywords only" : ""))
    }

    private func audio(_ file: FileRecord, pieces: [MediaPiece], duration: Double) throws -> (String, String?) {
        guard !pieces.isEmpty else {
            try store.finish(file.id, state: "skipped", detail: "silent or shorter than 2 s")
            return ("skipped", "silent or too short")
        }
        let vectors = try fullWorker().embedAudio(pieces.map(\.path))
        try store.db.transaction {
            for (piece, embedding) in zip(pieces, vectors) {
                try store.addSegment(file: file.id, kind: .audio, modality: .audio, loc: piece.start, locEnd: piece.end,
                                     vector: embedding.vector)
            }
            try store.finish(file.id, state: "done", info: ["duration": String(format: "%.1f", duration)])
        }
        return ("done", "\(pieces.count) windows, \(Int(duration)) s")
    }

    private func video(_ file: FileRecord, frames: [MediaPiece], sound: [MediaPiece], duration: Double) throws
        -> (String, String?) {
        guard !frames.isEmpty || !sound.isEmpty else {
            try store.finish(file.id, state: "skipped", detail: "no frames or sound")
            return ("skipped", "no frames or sound")
        }
        let worker = try fullWorker()
        let frameVectors = try worker.embedImages(frames.map(\.path), budget: options.frameBudget)
        let soundVectors = try worker.embedAudio(sound.map(\.path))
        try store.db.transaction {
            for (frame, embedding) in zip(frames, frameVectors) {
                try store.addSegment(file: file.id, kind: .frame, modality: .image, loc: frame.start,
                                     locEnd: frame.end, vector: embedding.vector)
            }
            for (piece, embedding) in zip(sound, soundVectors) {
                try store.addSegment(file: file.id, kind: .audio, modality: .audio, loc: piece.start,
                                     locEnd: piece.end, vector: embedding.vector)
            }
            try store.finish(file.id, state: "done", info: ["duration": String(format: "%.1f", duration),
                                                            "frames": "\(frames.count)", "sound_windows": "\(sound.count)"])
        }
        return ("done", "\(frames.count) frames, \(sound.count) sound windows, \(Int(duration)) s")
    }
}
