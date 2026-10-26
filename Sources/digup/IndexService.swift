import DigUpKit
import Foundation
#if os(Windows)
import WinSDK
#endif

/// `digup index-service`: the app's indexing helper, one process per stretch of work.
///
/// Extraction (Vision OCR, ImageIO, PDFKit, AVFoundation) runs here and not in the app. Vision alone keeps ~100 MB
/// of models cached in whatever process ran OCR (measured: the app went from 16 to 93 MB after indexing 11
/// screenshots, and stayed there), and all of it goes back to the system when this process exits.
///
/// Protocol: one command per line on stdin, one JSON event per line on stdout.
///   stdin:  sync | sync code | stop | backfill on | backfill off      (EOF = stop)
///   stdout: {"event": "missing" | "pruned" | "sync" | "file" | "rest" | "summary" | "waiting" | "idle" | "error" |
///            "exit", ...}; events about the code index say "code": true
///
/// New file/code demand shares a bounded pipeline before optional long-file completion.
/// Sync, stop, schedules, and foreground holds are checked between complete inference batches.
///
/// Before the model has downloaded it only syncs (file names are searchable at once), says it's "waiting", and exits.
/// Folders that aren't there (an unplugged drive) or can't be read are skipped, and what was indexed from them stays.
/// That's checked before every sync, not once: a drive ejected while this runs must not crawl as "all deleted".
final class IndexService: @unchecked Sendable {
    /// One index: its store, its indexer, its folders.
    struct Part {
        let store: IndexStore
        let indexer: Indexer
        /// The chosen folders, there or not.
        let roots: [URL]
        /// When set, files under none of these folders leave the index (folders taken out of the app).
        let keepOnly: [URL]?
        var code: Bool { store.file.lastPathComponent == IndexStore.codeFile }
    }

    private let main: Part
    /// The code index (`--code-root`), when there are code folders.
    private let code: Part?
    /// The index folder (where `Watchdog` leaves a note about a file it stopped on).
    private let folder: URL
    private let model: SharedEmbedder
    /// The last report of folders that aren't there or can't be read, by index (said again only when it changes).
    private var unavailable: [Bool: (missing: [String], unreadable: [String])] = [:]
    private let modelReady: () -> Bool
    private let newFilesLimit: Int
    private let linger: Double
    private let output: (([String: Any]) -> Void)?
    private let beforeScanFolder: (@Sendable (URL) -> Void)?

    private let lock = NSLock()
    private var syncRequested = true       // the first thing it does
    private var codeSyncRequested = true
    private var changedPaths: [Bool:Set<String>] = [:]
    private var preferredFolders: [Bool:String] = [:]
    private var priorityRevision=0
    private var stopRequested = false
    private var inferenceFailure = false
    private var backfillAllowed: Bool
    /// A sync asked for while files are being indexed waits until then. A crawl of a big folder can take minutes, and
    /// a folder that keeps changing asks for the next one meanwhile: yielding at once, every pass went back to crawling
    /// before a single file was read. Indexing gets at least as long as the sync before it (2 s at the least).
    private var yieldAt = Date.distantPast
    private var foregroundUntil = 0.0
    private let wake = DispatchSemaphore(value: 0)

    init(main: Part, code: Part?, folder: URL, model: SharedEmbedder, modelReady: @escaping () -> Bool,
         backfill: Bool, newFilesLimit: Int, linger: Double, output: (([String: Any]) -> Void)? = nil,
         beforeScanFolder: (@Sendable (URL) -> Void)? = nil) {
        self.main = main
        self.code = code
        self.folder = folder
        self.model = model
        self.modelReady = modelReady
        self.backfillAllowed = backfill
        self.newFilesLimit = newFilesLimit
        self.linger = linger
        self.output = output
        self.beforeScanFolder = beforeScanFolder
        self.model.beforeInference = { [weak self] in self?.yieldToSearch() }
    }

    private func yieldToSearch() {
        var reported = false
        while lock.withLock({ !stopRequested && ProcessInfo.processInfo.systemUptime < foregroundUntil }) {
            if !reported { emit(["event":"foreground_hold","state":"waiting"]); reported = true }
            Thread.sleep(forTimeInterval:0.025)
        }
        if reported { emit(["event":"foreground_hold","state":"resumed"]) }
    }

    private var parts: [Part] { [main] + (code.map { [$0] } ?? []) }

    private func emit(_ fields: [String: Any]) {
        if let output { output(fields) } else { emitServiceOutput(fields) }
    }

    func serve(commandInput: Bool = true) -> Int32 {
        emit(["event": "phase", "stage": "cleanup", "message": "Preparing indexing scratch space…"])
        removeStaleScratchFolders()
        do {
            emit(["event": "phase", "stage": "checking_index", "message": "Checking the file index…"])
            // A file an earlier helper had to stop on (`Watchdog`) isn't read again until it changes.
            if let stopped = StoppedFile.take(from: folder), let path = stopped.path {
                for part in parts {
                    guard try part.store.markStopped(path, why: stopped.why) else { continue }
                    emit(["event": "stopped", "path": path, "why": stopped.why, "code": part.code])
                }
            }
            let again = try main.store.readAgainOnce()   // what older indexes couldn't read: scans' words, SVGs
            if again > 0 { emit(["event": "rescan", "files": again]) }
            for part in parts {
                try part.indexer.checkModel()   // a new model: everything is queued again
                if let keepOnly = part.keepOnly {
                    let pruned = try part.store.prune(keepingUnder: keepOnly.map(\.path))
                    if pruned > 0 { emit(["event": "pruned", "files": pruned, "code": part.code]) }
                }
            }
        } catch {
            emit(["event": "error", "message": "\(error)", "fatal": true])
            finish()
            return 1
        }
        if commandInput { Thread.detachNewThread { [self] in readCommands() } }
        var newFiles = Set<Int64>(), newCode = Set<Int64>()
        var exitStatus: Int32 = 0
        while true {
            let requests = lock.withLock { () -> (Bool,Bool,[Bool:Set<String>]) in
                defer { syncRequested=false;codeSyncRequested=false;changedPaths.removeAll() }
                return (syncRequested,codeSyncRequested,changedPaths)
            }
            var scans: [Part] = []
            if requests.0 { scans.append(main) }
            if requests.1, let code { scans.append(code) }
            if !scans.isEmpty {
                let queued = scan(scans,changed:requests.2)
                newFiles.formUnion(queued[false] ?? [])
                newCode.formUnion(queued[true] ?? [])
            }
            if inferenceFailure { exitStatus=1 }
            if lock.withLock({ stopRequested }) { break }
            guard modelReady() else {
                emitCounts("waiting", ["for": "model"])
                break
            }
            let backfill = lock.withLock { backfillAllowed }
            if !newFiles.isEmpty || !newCode.isEmpty || backfill && parts.contains(where: { ((try? $0.store.pendingCount()) ?? 0) > 0 }) {
                guard runSources(newFiles: &newFiles, newCode: &newCode, backfill: backfill) else {
                    exitStatus = 1
                    break
                }
                if lock.withLock({ stopRequested }) { break }
                if lock.withLock({ syncRequested || codeSyncRequested && code != nil }) { continue }
                if !newFiles.isEmpty || !newCode.isEmpty { continue }
                if lock.withLock({ backfillAllowed }), parts.contains(where: { ((try? $0.store.pendingCount()) ?? 0) > 0 }) { continue }
            }
            if lock.withLock({ backfillAllowed }), (try? main.store.pendingCount()) ?? 1 == 0,
               (try? code?.store.pendingCount() ?? 0) ?? 1 == 0, (try? main.store.unfinishedCount().files) ?? 0 > 0 {
                guard finishLongFiles() else { exitStatus = 1; break }
                if lock.withLock({ syncRequested || codeSyncRequested && code != nil }) { continue }
            }
            if code != nil, lock.withLock({ codeSyncRequested }) { continue }
            emitCounts("idle")
            guard model.isRunning, waitForWork() else { break }
        }
        finish()
        emit(["event": "exit"])
        return exitStatus
    }

    private func finish() {
        for part in parts { part.indexer.finish() }
        model.close()
    }

    /// Scratch folders ($TMPDIR/DigUp-<pid>) of indexing processes that are gone (killed mid-batch).
    private func removeStaleScratchFolders() {
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] {
            guard name.hasPrefix("DigUp-"), let pid = Int32(name.dropFirst("DigUp-".count)),
                  pid != ProcessInfo.processInfo.processIdentifier, Self.isGone(pid) else { continue }
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    /// No process has this id now.
    private static func isGone(_ pid: Int32) -> Bool {
        #if os(Windows)
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else { return true }
        defer { CloseHandle(process) }
        var code: DWORD = 0
        return GetExitCodeProcess(process, &code) && code != 259   // STILL_ACTIVE
        #else
        return kill(pid, 0) != 0 && errno == ESRCH
        #endif
    }

    /// A part's chosen folders that are there and readable right now; also what `pending` and the counts look at.
    private func availableRoots(_ part: Part) -> [URL] {
        var missing: [URL] = [], unreadable: [URL] = []
        for root in part.roots {
            emit(["event": "phase", "stage": "checking_folder", "path": root.path, "code": part.code,
                  "message": "Checking selected folders…"])
            if !Arguments.isFolder(root) { missing.append(root) }
            else if !Arguments.isReadable(root) { unreadable.append(root) }
        }
        let report = (missing.map(\.path), unreadable.map(\.path))
        if unavailable[part.code].map({ $0 != report }) ?? !(missing.isEmpty && unreadable.isEmpty) {
            emit(["event": "missing", "folders": report.0, "unreadable": report.1, "code": part.code])
        }
        unavailable[part.code] = report
        let available = part.roots.filter { !missing.contains($0) && !unreadable.contains($0) }
        part.store.scope = available.map(\.path)
        return available
    }

    private func priorityProvider(_ active: [Part]) -> () -> (Int,String)? {
        var revision = -1
        var pending: [(Int,String)] = []
        return { [self] in
            lock.withLock {
                if revision != priorityRevision {
                    revision=priorityRevision
                    pending=active.indices.compactMap {source in
                        preferredFolders[active[source].code].map {(source,$0)}
                    }
                }
                return pending.isEmpty ? nil : pending.removeFirst()
            }
        }
    }

    private final class ScanWork {
        let part: Part
        let session: IndexScanSession
        let stream: CrawlStream
        var summary: Indexer.SyncSummary?
        var finished = false
        init(part: Part, session: IndexScanSession, stream: CrawlStream) {
            self.part=part;self.session=session;self.stream=stream
        }
    }

    private func rootsForChanges(_ paths: Set<String>, part: Part, available: [URL]) -> [URL] {
        var selected=Set<String>()
        for path in paths {
            let url=URL(fileURLWithPath:path).standardizedFileURL
            guard let root=available.filter({url.path==$0.path || FolderSelection.isInside(url.path,$0.path)})
                .max(by:{$0.path.count<$1.path.count}) else {continue}
            if url.lastPathComponent==".gitignore" || url.path.contains("/.git/") ||
                Rules.projectMarkerChanged(url.lastPathComponent) {
                selected.insert(root.path);continue
            }
            var parent=url.deletingLastPathComponent()
            if url.path==root.path {parent=root}
            while !Arguments.isFolder(parent) && parent.path.count>root.path.count {parent=parent.deletingLastPathComponent()}
            if parent.path.count<root.path.count {parent=root}
            if !Crawler.canScanSubtree(parent,selectedRoots:part.roots,options:part.indexer.scanOptions) {parent=root}
            let canonical=parent.resolvingSymlinksInPath().standardizedFileURL.path
            if !canonical.utf8.elementsEqual(parent.path.utf8) {selected.insert(root.path)}
            else {selected.insert(parent.path)}
        }
        return selected.filter {path in !selected.contains {other in path != other && FolderSelection.isInside(path,other)}}
            .sorted().map {URL(fileURLWithPath:$0,isDirectory:true)}
    }

    private func scan(_ requested: [Part], changed: [Bool:Set<String>] = [:]) -> [Bool:Set<Int64>] {
        let started=Date()
        var work: [ScanWork] = []
        defer {
            for item in work { item.stream.cancel() }
            for item in work { item.stream.close();item.session.close() }
            lock.withLock { yieldAt=Date()+max(Date().timeIntervalSince(started),2) }
        }
        var result: [Bool:Set<Int64>] = [:]
        do {
            let gate=NSLock()
            for part in requested {
                let available=availableRoots(part)
                let roots=changed[part.code].map {rootsForChanges($0,part:part,available:available)} ?? available
                let session=try part.indexer.beginScan(roots)
                let stream=CrawlStream(roots:roots,options:part.indexer.scanOptions,selectedRoots:part.roots,
                    beforeFolder:beforeScanFolder,scanGate:gate)
                work.append(ScanWork(part:part,session:session,stream:stream))
                emit(["event":"scanning","code":part.code,"discoveryActive":true])
            }
            var lastCounts=0.0
            func drain() throws {
                for _ in 0..<8 {
                for item in work where !item.finished {
                    guard let event=item.stream.take() else { continue }
                    switch event {
                    case .progress(let progress):
                        emit(["event":"scan_progress","stage":progress.stage,"root":progress.root,"path":progress.path,
                              "visited":progress.visited,"candidates":progress.candidates,"code":item.part.code,
                              "discoveryActive":true])
                    case .batch(let candidates):
                        _ = try item.session.admit(candidates)
                        let now=ProcessInfo.processInfo.systemUptime
                        if now-lastCounts>=0.5 {
                            emitCounts("scan_batch",["code":item.part.code,"discoveryActive":true,
                                "candidates":item.session.eligibleCount])
                            lastCounts=now
                        }
                    case .finished(let report):
                        item.summary=try item.session.finish(report)
                        item.finished=true
                        if let summary=item.summary {
                            emitCounts("sync",[
                                "code":item.part.code,"new":item.session.queuedCount<=newFilesLimit ? item.session.queuedCount : 0,
                                "added":summary.added,"changed":summary.changed,"moved":summary.moved,
                                "removed":summary.removed,"unchanged":summary.unchanged,
                                "ms":Int(Date().timeIntervalSince(started)*1000),"started":started.timeIntervalSince1970,
                                "visited":report.visited,"candidates":report.candidateCount,"skipped":report.skipped,
                                "skippedFolders":report.skippedFolders,"unreadable":report.unreadable.sorted(),
                                "discoveryActive":false])
                        }
                    case .failed(let message):
                        item.finished=true
                        emit(["event":"error","message":"sync failed: \(message)","code":item.part.code,
                            "discoveryActive":false])
                    }
                }
                }
            }
            let mayEmbed=modelReady() && lock.withLock { backfillAllowed }
            if mayEmbed {
                while !work.contains(where:{$0.session.eligibleCount>0}) && !work.allSatisfy(\.finished)
                    && !lock.withLock({stopRequested}) {
                    try drain()
                    Thread.sleep(forTimeInterval:0.005)
                }
                emit(["event":"phase","stage":"discovering_and_indexing",
                    "message":"Discovering files and indexing ready content…","discoveryActive":true,
                    "code":requested.allSatisfy(\.code)])
                do {
                    _ = try Indexer.runScheduled(work.map { .init(indexer:$0.part.indexer,includePending:false) },
                        shouldStop:{ [self] in lock.withLock { stopRequested || !backfillAllowed } },
                        onEvent:{ [self] source,_,event in
                            let item=work[source]
                            if event.note=="source_changed" {
                                lock.withLock {
                                    if item.part.code {codeSyncRequested=true}else{syncRequested=true}
                                }
                            }
                            emit(["event":"file","new":false,"path":event.path,"kind":event.kind.rawValue,
                                "state":event.state,"seconds":event.seconds,"note":event.note ?? "",
                                "code":item.part.code,"discoveryActive":!item.finished])
                        },onSnapshot:{ [self] snapshot in
                            for source in work.indices {
                                var own=snapshot;own.source=String(source)
                                if let fields=try? JSONSerialization.jsonObject(with:JSONEncoder().encode(own)) {
                                    emit(["event":"index_pipeline","code":work[source].part.code,"pipeline":fields])
                                }
                            }
                        },onVerified:{ [self] info in
                            var fields=info.fields
                            fields["event"]="inference_verified";fields["inference_verified"]=true
                            emit(fields)
                        },admit:{
                            try drain()
                            return try work.map { try $0.session.takeEligibleIDs() }
                        },inputComplete:{work.allSatisfy(\.finished)},priority:priorityProvider(work.map(\.part)),maintenance:drain)
                } catch {
                    inferenceFailure=true
                    lock.withLock {stopRequested=true}
                    for item in work {item.stream.cancel()}
                    emit(["event":"error","message":"Indexing failed: \(error)","fatal":true])
                }
            }
            while !work.allSatisfy(\.finished) && !lock.withLock({stopRequested}) {
                try drain()
                Thread.sleep(forTimeInterval:0.005)
            }
            for item in work {
                if let summary=item.summary,item.session.queuedCount<=newFilesLimit {
                    result[item.part.code]=Set(summary.queued)
                }
                if !item.finished { emit(["event":"scan_cancelled","code":item.part.code,"discoveryActive":false]) }
            }
            if inferenceFailure { lock.withLock {stopRequested=true} }
        } catch {
            emit(["event":"error","message":"sync failed: \(error)","discoveryActive":false])
        }
        return result
    }

    private func runSources(newFiles: inout Set<Int64>, newCode: inout Set<Int64>, backfill: Bool) -> Bool {
        let active = parts
        let sources = active.map { part in
            Indexer.ScheduleSource(indexer: part.indexer, priorityIDs: part.code ? newCode : newFiles,
                                   includePending: backfill)
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let states = try Indexer.runScheduled(sources, shouldStop: { [self] in
                lock.withLock {
                    stopRequested || backfillAllowed != backfill
                        || Date() >= yieldAt && (syncRequested || codeSyncRequested && code != nil)
                }
            }, onEvent: { [self] source, isNew, event in
                let part = active[source]
                if event.state != "pending" {
                    if part.code { newCode.remove(event.fileID) } else { newFiles.remove(event.fileID) }
                }
                if event.note == "source_changed" {
                    lock.withLock {
                        if part.code { codeSyncRequested = true } else { syncRequested = true }
                        yieldAt = .distantPast
                    }
                }
                emit(["event": "file", "new": isNew, "done": event.done, "total": event.total, "path": event.path,
                      "kind": event.kind.rawValue, "state": event.state, "seconds": event.seconds,
                      "note": event.note ?? "", "code": part.code])
            }, onSnapshot: { [self] snapshot in
                for source in active.indices {
                    var own = snapshot
                    own.source = String(source)
                    guard let data = try? JSONEncoder().encode(own),
                          let fields = try? JSONSerialization.jsonObject(with: data) else { continue }
                    emit(["event": "index_pipeline", "code": active[source].code, "pipeline": fields])
                }
            }, onRemaining: { source, remaining in
                if active[source].code { newCode = remaining } else { newFiles = remaining }
            }, onVerified: { [self] info in
                var fields = info.fields
                fields["event"] = "inference_verified"
                fields["inference_verified"] = true
                emit(fields)
            },priority:priorityProvider(active))
            for source in active.indices where !states[source].isEmpty {
                emit(["event": "summary", "states": states[source], "code": active[source].code,
                      "ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000)])
            }
            return true
        } catch {
            emit(["event": "error", "message": "\(error)", "fatal": true])
            return false
        }
    }

    /// The rest of long files (`Indexer.finishLongFiles`), yielding as the backfill does. False when indexing has to
    /// stop.
    private func finishLongFiles() -> Bool {
        defer { emitPipeline(main) }
        let started = Date()
        do {
            let states = try main.indexer.finishLongFiles(shouldStop: { [self] in
                lock.withLock {
                    stopRequested || !backfillAllowed
                        || Date() >= yieldAt && (syncRequested || codeSyncRequested && code != nil)
                }
            }, onStep: { [self] step in
                if step.note=="source_changed" {lock.withLock {syncRequested=true;yieldAt = .distantPast}}
                emit(["event": "rest", "done": step.done, "total": step.total, "files": step.files, "path": step.path,
                      "kind": step.kind.rawValue, "state": step.state, "seconds": step.seconds, "note": step.note ?? ""])
            })
            if !states.isEmpty {
                emit(["event": "summary", "rest": true, "states": states,
                      "ms": Int(Date().timeIntervalSince(started) * 1000)])
            }
            return true
        } catch {
            emit(["event": "error", "message": "\(error)", "fatal": true])
            return false
        }
    }

    private func emitPipeline(_ part: Part) {
        guard let snapshot = part.indexer.lastPipeline,
              let data = try? JSONEncoder().encode(snapshot),
              let fields = try? JSONSerialization.jsonObject(with: data) else { return }
        emit(["event": "index_pipeline", "code": part.code, "pipeline": fields])
    }

    /// Waits up to `linger` seconds for something to do. False: time's up, or told to stop.
    private func waitForWork() -> Bool {
        let deadline = DispatchTime.now() + linger
        while wake.wait(timeout: deadline) == .success {
            let (sync, codeSync, stop, backfill) = lock.withLock {
                (syncRequested, codeSyncRequested, stopRequested, backfillAllowed)
            }
            if stop { return false }
            if sync || codeSync && code != nil { return true }
            if backfill, parts.contains(where: { (try? $0.store.pendingCount()) ?? 0 > 0 })
                || (try? main.store.unfinishedCount().files) ?? 0 > 0 {
                return true
            }
        }
        return false
    }

    func accept(_ line: String) {
        if line.utf8.count<=1024*1024,let data=line.data(using:.utf8),
           let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
           request["command"] as? String=="prioritize",
           let path=request["path"] as? String {
            let isCode=request["code"] as? Bool ?? false
            if let part=parts.first(where:{$0.code==isCode}),
               part.roots.contains(where:{$0.path==path || FolderSelection.isInside(path,$0.path)}) {
                lock.withLock {preferredFolders[isCode]=path;priorityRevision+=1}
                wake.signal()
            }
            return
        }
        if line.utf8.count<=1024*1024,let data=line.data(using:.utf8),
           let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
           request["command"] as? String=="changes" {
            let isCode=request["code"] as? Bool ?? false
            guard let part=parts.first(where:{$0.code==isCode}) else {return}
            let paths=(request["paths"] as? [String] ?? []).map {URL(fileURLWithPath:$0).standardizedFileURL.path}
            let dirty=request["dirtyRoots"] as? [String] ?? []
            let valid=Set(paths.filter {path in
                part.roots.contains {root in path==root.path || FolderSelection.isInside(path,root.path)}
            })
            lock.withLock {
                let alreadyRequested=isCode ? codeSyncRequested : syncRequested
                if !dirty.isEmpty || paths.count>1024 || valid.count != Set(paths).count {
                    changedPaths[isCode]=nil
                } else if !alreadyRequested || changedPaths[isCode] != nil {
                    changedPaths[isCode,default:[]].formUnion(valid)
                    if (changedPaths[isCode]?.count ?? 0)>1024 {changedPaths[isCode]=nil}
                }
                if isCode {codeSyncRequested=true}else{syncRequested=true}
            }
            wake.signal()
            return
        }
        lock.withLock {
            switch line.trimmingCharacters(in: .whitespaces) {
            case "sync": syncRequested = true; changedPaths[false]=nil
            case "sync code": codeSyncRequested = true; changedPaths[true]=nil
            case "stop": stopRequested = true
            case "backfill on": backfillAllowed = true
            case "backfill off": backfillAllowed = false
            case "foreground": foregroundUntil = ProcessInfo.processInfo.systemUptime + 1
            default: break
            }
        }
        wake.signal()
    }

    private func readCommands() {
        while let line = readLine() { accept(line) }
        accept("stop")
    }

    /// An event with both indexes' counts: the main one's as they are, the code index's prefixed "code_".
    private func emitCounts(_ event: String, _ extra: [String: Any] = [:]) {
        var fields = extra
        fields["event"] = event
        for part in parts {
            guard let counts = try? part.store.counts() else { continue }
            let prefix = part.code ? "code_" : ""
            var files = 0, searchable = 0, pending = 0
            for states in counts.byKindAndState.values {
                for (state, count) in states {
                    files += count
                    if state == "done" || state == "partial" { searchable += count }
                    if state == "pending" { pending += count }
                }
            }
            fields[prefix + "files"] = files
            fields[prefix + "searchable"] = searchable
            fields[prefix + "pending"] = pending
            fields[prefix + "vectors"] = counts.vectors
            if !part.code { fields["unfinished"] = counts.unfinished }   // long files with pages or chunks left to read
        }
        emit(fields)
    }
}

/// Both indexes share one lazy provider, which can own a GPU worker pool. Only the service closes it.
final class SharedEmbedder: @unchecked Sendable {
    var beforeInference: (() -> Void)?
    private let make: () throws -> any Embedder
    private var model: (any Embedder)?

    init(_ make: @escaping () throws -> any Embedder) {
        self.make = make
    }

    var isRunning: Bool { model != nil }

    func embedder() throws -> any Embedder {
        if model == nil { beforeInference?(); model = try make() }
        return Kept(model!, beforeInference)
    }

    func close() {
        model?.close()
        model = nil
    }

    private final class Kept: ParallelEmbedding, InferenceReporting {
        var maximumParallelJobs: Int { (model as? any ParallelEmbedding)?.maximumParallelJobs ?? 1 }
        var inferenceActivity: InferenceActivity? { (model as? any InferenceReporting)?.inferenceActivity }
        let model: any Embedder
        let before: (() -> Void)?
        init(_ model: any Embedder, _ before: (() -> Void)?) { self.model = model; self.before = before }
        var info: WorkerInfo { model.info }
        func embedTexts(_ texts: [String]) throws -> [[Float]] { before?(); return try model.embedTexts(texts) }
        func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
            before?(); return try model.embedImages(paths, budget: budget)
        }
        func embedAudio(_ paths: [String]) throws -> [Embedding] { before?(); return try model.embedAudio(paths) }
        func close() {}
    }
}

/// One JSON object per line on stdout, written straight to the file descriptor (print() would buffer in a pipe).
/// The app may be gone by now (it quit while this helper lingered): a closed pipe is an error to ignore here, not the
/// exception that `write(_:)` raises, which used to crash the helper on its way out.
private enum ProtocolOutput { static let lock=NSLock() }
func emitInference(_ activity: InferenceActivity) {
    guard let data=try? JSONEncoder().encode(activity),let fields=try? JSONSerialization.jsonObject(with:data) else{return}
    emit(["event":"inference_activity","activity":fields])
}
func emit(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    ProtocolOutput.lock.withLock { try? FileHandle.standardOutput.write(contentsOf: data + [0x0A]) }
}

private func emitServiceOutput(_ fields: [String: Any]) { emit(fields) }
