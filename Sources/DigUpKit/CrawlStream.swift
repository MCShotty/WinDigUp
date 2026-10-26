import Foundation

public enum CrawlStreamEvent: Sendable {
    case progress(CrawlProgress)
    case batch([Candidate])
    case finished(CrawlReport)
    case failed(String)
}

/// The scanner owns this queue; only the indexing coordinator consumes it.
public final class CrawlStream: @unchecked Sendable {
    private let condition = NSCondition()
    private let worker = DispatchGroup()
    private var events: [CrawlStreamEvent] = []
    private var cancelled = false
    private var ended = false
    private var peakQueued = 0
    public var peakQueuedBatches: Int {
        condition.lock()
        defer {condition.unlock()}
        return peakQueued
    }
    public let capacity: Int

    public init(roots: [URL], options: IndexOptions, selectedRoots: [URL]? = nil, capacity: Int = 4,
                beforeFolder: (@Sendable (URL) -> Void)? = nil, scanGate: NSLock? = nil) {
        self.capacity = max(1, min(16, capacity))
        worker.enter()
        DispatchQueue(label: "DigUp.scan", qos: .utility).async { [self] in
            defer { worker.leave() }
            do {
                let report = try Crawler.scan(roots, options: options, selectedRoots: selectedRoots,
                    shouldStop: { self.isCancelled },
                    beforeFolder: beforeFolder, scanGate: scanGate,
                    onProgress: { self.send(.progress($0)) },
                    onBatch: { self.send(.batch($0)) })
                if !isCancelled { send(.finished(report)) }
            } catch {
                if !isCancelled { send(.failed(String(describing: error))) }
            }
            condition.lock()
            ended = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    private func send(_ event: CrawlStreamEvent) {
        condition.lock()
        defer { condition.unlock() }
        while !cancelled && events.count >= capacity { condition.wait() }
        guard !cancelled else { return }
        events.append(event)
        peakQueued = max(peakQueued, events.count)
        condition.broadcast()
    }

    public func take() -> CrawlStreamEvent? {
        condition.lock()
        defer { condition.unlock() }
        guard !events.isEmpty else { return nil }
        let event = events.removeFirst()
        condition.broadcast()
        return event
    }

    public var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return ended && events.isEmpty
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    public func close() {
        cancel()
        worker.wait()
    }
}

extension Crawler {
    public static func canScanSubtree(_ folder:URL,selectedRoots:[URL],options:IndexOptions) -> Bool {
        selectedRoots.contains {selection in
            let root=selection.standardizedFileURL.path
            let path=folder.standardizedFileURL.path
            guard path==root || FolderSelection.isInside(path,root) else{return false}
            if path==root {return true}
            let canonicalRoot=FolderSelection.realPath(root)
            let excluded=options.excludedFolders.flatMap {skip -> [String] in
                let canonical=FolderSelection.realPath(skip)
                if FolderSelection.isInside(canonical,canonicalRoot) {
                    return [skip,canonical,root+String(canonical.dropFirst(canonicalRoot.count))]
                }
                return FolderSelection.isInside(skip,root) ? [skip] : []
            }
            guard Rules.isWalked(path,root:root,home:FileManager.default.homeDirectoryForCurrentUser.path,excluded:excluded) else{return false}
            var current=folder
            while current.path != root {
                if options.code && Rules.codeSkipReason(forFolder:current) != nil {return false}
                let values=try? current.resourceValues(forKeys:[.isPackageKey,.isHiddenKey,.isSymbolicLinkKey])
                if values?.isHidden==true || values?.isSymbolicLink==true {return false}
                if FileSystem.isPackage(current,values) {return false}
                let parent=current.deletingLastPathComponent()
                if parent.path==current.path {return false}
                current=parent
            }
            return true
        }
    }

    private static func scanProjectRoot(_ folder:String) -> Bool {
        if FileManager.default.fileExists(atPath:folder+"/.git") {return true}
        let url=URL(fileURLWithPath:folder,isDirectory:true)
        #if os(Windows)
        guard let walker=FileSystem.directory(url) else {return false}
        #else
        guard let walker=FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.isDirectoryKey],
            options:[.skipsHiddenFiles,.skipsPackageDescendants]) else {return false}
        #endif
        while let child=autoreleasepool(invoking:{walker.nextObject() as? URL}) {
            let name=child.lastPathComponent
            if Rules.projectMarkers.contains(name) || Rules.projectBundleExtensions.contains(child.pathExtension) {return true}
            #if os(Windows)
            if walker.currentIsDirectory {walker.skipDescendants()}
            #else
            if (try? child.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true {walker.skipDescendants()}
            #endif
        }
        return false
    }

    /// A directory is classified before its media can enter inference.
    public static func scan(_ roots: [URL], options: IndexOptions, selectedRoots: [URL]? = nil,
        shouldStop: () -> Bool = { false },
        beforeFolder: (@Sendable (URL) -> Void)? = nil, scanGate: NSLock? = nil,
        onProgress: (CrawlProgress) -> Void = { _ in },
        onBatch: ([Candidate]) -> Void) throws -> CrawlReport {
        let fm = FileManager.default
        let db = try Database(path: ":memory:")
        try db.execute("""
            PRAGMA temp_store=FILE; PRAGMA temp.cache_size=-2048;
            CREATE TEMP TABLE seen(path TEXT PRIMARY KEY);
            CREATE TEMP TABLE folders(id INTEGER PRIMARY KEY,path TEXT NOT NULL,project INTEGER NOT NULL);
            CREATE TEMP TABLE candidates(id INTEGER PRIMARY KEY,path TEXT NOT NULL,kind TEXT NOT NULL,
                size INTEGER NOT NULL,mtime REAL NOT NULL,inode INTEGER NOT NULL,device INTEGER NOT NULL);
            """)
        let selections=selectedRoots ?? roots
        let rootPaths = Set(selections.flatMap { [$0.standardizedFileURL.path,FolderSelection.realPath($0.path)] })
        let home = fm.homeDirectoryForCurrentUser.path
        var report = CrawlReport()
        var repos = GitRepos()
        var lastProgress = 0.0
        func progress(_ stage: String, root: String, path: String, force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || now - lastProgress >= 0.5 else { return }
            lastProgress = now
            onProgress(CrawlProgress(stage: stage, root: root, path: path,
                visited: report.visited, candidates: report.candidateCount))
        }
        for root in roots.map({ $0.standardizedFileURL }) {
            if shouldStop() { break }
            progress("root", root: root.path, path: root.path, force: true)
            if selectedRoots != nil && !Crawler.canScanSubtree(root,selectedRoots:selections,options:options) {continue}
            let real = FolderSelection.realPath(root.path)
            let skips = options.excludedFolders.filter {
                FolderSelection.isInside($0, root.path) || FolderSelection.isInside($0, real)
            }.flatMap { [$0, FolderSelection.realPath($0)] }
            if options.code { repos.enterRoot(root.path) }
            var inheritedProject = false
            if !options.code {
                for selected in selections.flatMap({ [$0.standardizedFileURL.path,FolderSelection.realPath($0.path)] })
                    where FolderSelection.isInside(real, selected) {
                    var ancestor = (real as NSString).deletingLastPathComponent
                    while ancestor.count >= selected.count {
                        if Crawler.scanProjectRoot(ancestor) { inheritedProject = true; break }
                        let parent = (ancestor as NSString).deletingLastPathComponent
                        if parent == ancestor { break }
                        ancestor = parent
                    }
                }
            }
            try db.run("INSERT INTO folders(path,project) VALUES(?,?)",[.text(root.path),.int(inheritedProject ? 1 : 0)])
            while true {
                var nextFolder:(Int64,String,Bool)?
                try db.query("SELECT id,path,project FROM folders ORDER BY id DESC LIMIT 1") {
                    nextFolder=($0.int(0),$0.text(1) ?? "",$0.int(2) != 0)
                }
                guard let (folderID,path,inherited)=nextFolder else {break}
                try db.run("DELETE FROM folders WHERE id=?",[.int(folderID)])
                let folder=URL(fileURLWithPath:path,isDirectory:true)
                if shouldStop() { return report }
                beforeFolder?(folder)
                if shouldStop() { return report }
                scanGate?.lock()
                defer { scanGate?.unlock() }
                let inProject = !options.code && (inherited || Crawler.scanProjectRoot(folder.path))
                if options.code { repos.enter(folder.path) }
                #if os(Windows)
                guard let walker = FileSystem.directory(folder) else {
                    report.unreadable.insert(folder.path); continue
                }
                #else
                guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: FileSystem.crawlKeys+[.isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, _ in report.unreadable.insert(url.path); return true }) else {
                    report.unreadable.insert(folder.path); continue
                }
                #endif
                try db.execute("DELETE FROM candidates")
                var kindCounts: [FileKind: (count: Int, machine: Int)] = [:]
                var immediate: [Candidate] = []
                try db.transaction {
                    while let url = autoreleasepool(invoking: { walker.nextObject() as? URL }) {
                        if shouldStop() { break }
                        report.visited += 1
                        progress("entries", root: root.path, path: url.path)
                        #if os(Windows)
                        let values: URLResourceValues? = nil
                        let directory = walker.currentIsDirectory
                        #else
                        let values: URLResourceValues
                        do { values = try url.resourceValues(forKeys: Set(FileSystem.crawlKeys+[.isSymbolicLinkKey])) }
                        catch { report.unreadable.insert(url.path); walker.skipDescendants(); continue }
                        if values.isSymbolicLink==true {
                            report.skipped["link or special file",default:0] += 1
                            walker.skipDescendants()
                            continue
                        }
                        let directory = values.isDirectory == true
                        #endif
                        let package = FileSystem.isPackage(url, values)
                        if directory {
                            walker.skipDescendants()
                            if package { report.skipped["app or bundle", default: 0] += 1 }
                            else if let reason = Rules.skipReason(forFolder: url, home: home, excluded: skips)
                                ?? (options.code ? Rules.codeSkipReason(forFolder: url) : nil) {
                                report.skippedFolders[reason, default: 0] += 1
                            } else {
                                try db.run("INSERT INTO folders(path,project) VALUES(?,?)",
                                    [.text(url.path),.int(inProject ? 1 : 0)])
                            }
                            continue
                        }
                        if package { report.skipped["app or bundle", default: 0] += 1; continue }
                        let header = ["ts", "mts", "m2ts"].contains(url.pathExtension.lowercased())
                        var checked: FileInfo?
                        if header {
                            checked = FileSystem.info(of: url.path)
                            guard let info = checked else { report.unreadable.insert(url.path); continue }
                            if !info.isRegular { report.skipped["link or special file", default: 0] += 1; continue }
                            if info.dataless || FileSystem.isInCloud(values) {
                                report.skipped["in the cloud, not downloaded", default: 0] += 1; continue
                            }
                        }
                        let classification = options.code ? Rules.classifyCode(url, options: options)
                            : Rules.classify(url, values: values, options: options)
                        switch classification {
                        case .ignore: report.skipped["other type", default: 0] += 1
                        case .skip(let reason): report.skipped[reason, default: 0] += 1
                        case .index(let kind):
                            guard let info = checked ?? FileSystem.info(of: url.path) else {
                                report.unreadable.insert(url.path)
                                report.skipped["metadata unavailable", default: 0] += 1
                                continue
                            }
                            if !info.isRegular { report.skipped["link or special file", default: 0] += 1; continue }
                            if info.dataless || FileSystem.isInCloud(values) {
                                report.skipped["in the cloud, not downloaded", default: 0] += 1; continue
                            }
                            if !options.code && inProject && kind != .screenshot {
                                report.skipped["inside a code project", default: 0] += 1; continue
                            }
                            if options.code {
                                let limit = url.pathExtension.lowercased() == "ipynb" ? options.maxNotebookBytes : options.maxCodeBytes
                                if info.size > limit { report.skipped["too big to be written by hand", default: 0] += 1; continue }
                                if repos.ignores(url.path) { report.skipped["ignored by git", default: 0] += 1; continue }
                            }
                            try db.run("INSERT OR IGNORE INTO seen(path) VALUES(?)", [.text(url.path)])
                            var inserted = false
                            try db.query("SELECT changes()") { inserted = $0.int(0) != 0 }
                            if !inserted { continue }
                            let deferMedia = !options.code && !options.includeDatasets && !rootPaths.contains(folder.path)
                                && [.image,.audio,.video].contains(kind)
                            if deferMedia {
                                try db.run("INSERT INTO candidates(path,kind,size,mtime,inode,device) VALUES(?,?,?,?,?,?)",
                                    [.text(url.path),.text(kind.rawValue),.int(info.size),.double(info.mtime),
                                     .int(Int64(bitPattern: info.inode)),.int(Int64(bitPattern: info.device))])
                            } else {
                                immediate.append(Candidate(path:url.path,kind:kind,size:info.size,mtime:info.mtime,
                                    inode:info.inode,device:info.device))
                                if immediate.count == 64 {
                                    report.candidateCount += immediate.count
                                    onBatch(immediate)
                                    immediate.removeAll(keepingCapacity:true)
                                }
                            }
                            if deferMedia {
                                let stem = url.deletingPathExtension().lastPathComponent
                                let value = kindCounts[kind] ?? (0,0)
                                kindCounts[kind] = (value.count + 1, value.machine + (Rules.looksMachineNamed(stem) ? 1 : 0))
                            }
                        }
                    }
                }
                #if os(Windows)
                report.unreadable.formUnion(walker.unreadable)
                #endif
                if shouldStop() { return report }
                if !immediate.isEmpty {
                    report.candidateCount += immediate.count
                    onBatch(immediate)
                }
                let isDataset = !options.code && !options.includeDatasets && !rootPaths.contains(folder.path)
                    && kindCounts.values.contains { $0.count >= 300 && Double($0.machine) / Double($0.count) >= 0.7 }
                if isDataset {
                    let count = kindCounts.values.filter { $0.count >= 300 && Double($0.machine) / Double($0.count) >= 0.7 }
                        .reduce(0) { $0 + $1.count }
                    report.datasets[folder.path] = count
                }
                var after: Int64 = 0
                while true {
                    var batch: [Candidate] = []
                    try db.query("SELECT id,path,kind,size,mtime,inode,device FROM candidates WHERE id>? ORDER BY id LIMIT 64",
                        [.int(after)]) { row in
                        after = row.int(0)
                        guard let path = row.text(1), let raw = row.text(2), let kind = FileKind(rawValue: raw) else { return }
                        if isDataset && [.image,.audio,.video].contains(kind) {
                            report.skipped["dataset", default: 0] += 1
                        } else {
                            batch.append(Candidate(path:path,kind:kind,size:row.int(3),mtime:row.double(4),
                                inode:UInt64(bitPattern:row.int(5)),device:UInt64(bitPattern:row.int(6))))
                        }
                    }
                    if batch.isEmpty {
                        var more = false
                        try db.query("SELECT EXISTS(SELECT 1 FROM candidates WHERE id>?)", [.int(after)]) { more = $0.int(0) != 0 }
                        if !more { break }
                        continue
                    }
                    report.candidateCount += batch.count
                    onBatch(batch)
                    if shouldStop() { return report }
                }
            }
        }
        progress("complete",root:"",path:"",force:true)
        return report
    }
}
