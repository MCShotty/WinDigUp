import Foundation
import Testing
@testable import DigUpKit

@Suite(.serialized)
struct CrawlStreamingTests {
    func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func write(_ file:URL) throws {
        try "A useful railway timetable document.".write(to:file,atomically:false,encoding:.utf8)
    }

    @Test func batchesPublishBeforeTheWalkEndsAndStayBounded() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        for index in 0..<300 {try write(root.appendingPathComponent("note-\(index).txt"))}
        var received=0,peak=0
        let report=try Crawler.scan([root],options:IndexOptions(),shouldStop:{received>0},onBatch:{
            received += $0.count;peak=max(peak,$0.count)
        })
        #expect(received==64)
        #expect(peak<=64)
        #expect(report.visited<300)
    }

    @Test func datasetsAndCodeProjectsAgreeWithTheCompleteCrawler() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let dataset=root.appendingPathComponent("training")
        let project=root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:dataset,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        for index in 0..<320 {try Data([1]).write(to:dataset.appendingPathComponent("clip_\(1000+index).jpg"))}
        try write(root.appendingPathComponent("note.txt"))
        try write(project.appendingPathComponent("package.json"))
        try write(project.appendingPathComponent("private.txt"))
        try Data([1]).write(to:project.appendingPathComponent("Screenshot test.jpg"))
        var streamed:[Candidate]=[]
        let report=try Crawler.scan([root],options:IndexOptions(),onBatch:{streamed += $0})
        let legacy=Crawler.crawl([root],options:IndexOptions())
        #expect(Set(streamed.map(\.path))==Set(legacy.candidates.map(\.path)))
        #expect(report.skipped["dataset"]==320)
        #expect(report.candidateCount==streamed.count)
        #expect(report.skipped["inside a code project"]==legacy.skipped["inside a code project"])
    }

    @Test func partialRootsAndCancelledScansPreserveExistingNames() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        let first=files.appendingPathComponent("first.txt"),second=files.appendingPathComponent("second.txt")
        try write(first);try write(second)
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{throw FixtureError.noModel})
        _=try indexer.sync([files])
        let firstCandidate=try #require(Crawler.crawl([files],options:IndexOptions()).candidates.first{$0.path==first.path})
        let cancelled=try indexer.beginScan([files])
        _=try cancelled.admit([firstCandidate])
        cancelled.close()
        #expect(try store.files(under:[files.path]).count==2)
        let partial=try indexer.beginScan([files])
        _=try partial.admit([firstCandidate])
        var report=CrawlReport();report.unreadable.insert(second.path)
        _=try partial.finish(report)
        partial.close()
        #expect(try store.files(under:[files.path]).count==2)
    }

    @Test func renameReusesIdentityAndNamesAreCommittedBeforeCompletion() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        let old=files.appendingPathComponent("old.txt"),new=files.appendingPathComponent("renamed.txt")
        try write(old)
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{throw FixtureError.noModel})
        _=try indexer.sync([files])
        let id=try #require(store.files(under:[files.path]).first).id
        try FileManager.default.moveItem(at:old,to:new)
        let report=Crawler.crawl([files],options:IndexOptions())
        let scan=try indexer.beginScan([files])
        _=try scan.admit(report.candidates)
        let summary=try scan.finish(report)
        scan.close()
        let row=try #require(store.files(under:[files.path]).first)
        #expect(row.id==id)
        #expect(row.path==new.path)
        #expect(summary.moved==1)
        let extra=files.appendingPathComponent("extra.txt")
        try write(extra)
        let extraCandidate=try #require(Crawler.crawl([files],options:IndexOptions()).candidates.first{$0.path==extra.path})
        let next=try indexer.beginScan([files])
        _=try next.admit([extraCandidate])
        #expect(try store.files(under:[files.path]).count==2)
        next.close()
    }

    @Test func temporaryEmptyInputDoesNotFinishThePipeline() throws {
        var polls=0
        let pipeline=IndexPipeline<Int,Int,Int>(nextInput:{
            polls += 1
            return polls==4 ? 7 : nil
        },inputComplete:{polls>4},source:{_ in "files"},sizes:{_ in (0,0)},
        prepare:{_,value in value},cleanup:{_ in})
        defer {pipeline.close()}
        let item=try #require(pipeline.nextPrepared(shouldStop:{false}))
        #expect(item.value==7)
        pipeline.release(item,commitMs:0)
        #expect(pipeline.nextPrepared(shouldStop:{false})==nil)
        #expect(polls>=5)
    }

    @Test func ambiguousHardLinkDestinationsDoNotStealTheOldIdentity() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        let old=files.appendingPathComponent("old.txt")
        let first=files.appendingPathComponent("first.txt"),second=files.appendingPathComponent("second.txt")
        try write(old)
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{throw FixtureError.noModel})
        _=try indexer.sync([files])
        let oldID=try #require(store.files(under:[files.path]).first).id
        try FileManager.default.moveItem(at:old,to:first)
        try FileManager.default.linkItem(at:first,to:second)
        let report=Crawler.crawl([files],options:IndexOptions())
        let session=try indexer.beginScan([files])
        _=try session.admit(report.candidates)
        let summary=try session.finish(report)
        session.close()
        let rows=try store.files(under:[files.path])
        #expect(summary.moved==0)
        #expect(rows.count==2)
        #expect(!rows.contains{$0.id==oldID})
    }

    @Test func cancellingBackpressuredScannersReleasesTheirSharedGate() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        for index in 0..<160 {try write(root.appendingPathComponent("note-\(index).txt"))}
        let gate=NSLock()
        let first=CrawlStream(roots:[root],options:IndexOptions(),capacity:1,scanGate:gate)
        let second=CrawlStream(roots:[root],options:IndexOptions(),capacity:1,scanGate:gate)
        Thread.sleep(forTimeInterval:0.05)
        first.cancel();second.cancel()
        let start=Date()
        first.close();second.close()
        #expect(Date().timeIntervalSince(start)<5)
        #expect(first.peakQueuedBatches<=1 && second.peakQueuedBatches<=1)
    }

    @Test func priorityAndAppendedPagesDoNotLoseFilesAfterCursorReset() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let first=root.appendingPathComponent("first"),second=root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at:first,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try write(first.appendingPathComponent("a.txt"));try write(second.appendingPathComponent("b.txt"))
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{throw FixtureError.noModel})
        _=try indexer.sync([first,second])
        let queue=try store.pendingQueue()
        defer {queue.close()}
        queue.prioritize(second.path)
        #expect(try queue.take()?.file.path==second.appendingPathComponent("b.txt").path)
        #expect(try queue.take()?.file.path==first.appendingPathComponent("a.txt").path)
        #expect(try queue.take()==nil)
        let extra=first.appendingPathComponent("extra.txt")
        try write(extra)
        let candidate=try #require(Crawler.crawl([first],options:IndexOptions()).candidates.first{$0.path==extra.path})
        let id=try store.insert(candidate)
        try queue.append([id])
        #expect(try queue.take()?.file.id==id)
    }

    enum FixtureError:Error {case noModel}
}
