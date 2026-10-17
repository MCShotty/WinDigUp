import Foundation
import Testing
@testable import DigUpKit

struct IndexConcurrencyTests {
    final class Fake: ParallelEmbedding, @unchecked Sendable {
        let maximumParallelJobs=3
        let info=WorkerInfo(model:"fixture",revision:"fixture",runtime:"fixture",dtype:"fixture",
            dim:768,textOnly:false,loadSeconds:nil)
        let lock=NSCondition()
        var active=0,peak=0
        var change:URL?
        func embedTexts(_ texts:[String])throws->[[Float]] {
            lock.lock();active+=1;peak=max(peak,active);lock.broadcast()
            let until=Date().addingTimeInterval(0.1)
            while active<3 && Date()<until{_ = lock.wait(until:until)}
            let changed=change;change=nil
            lock.unlock()
            if let changed{try String(repeating:"Changed file contents. ",count:100).write(to:changed,atomically:true,encoding:.utf8)}
            Thread.sleep(forTimeInterval:0.01)
            lock.lock();active-=1;lock.broadcast();lock.unlock()
            return texts.map{_ in [Float(1)]+[Float](repeating:0,count:767)}
        }
        func embedImages(_ paths:[String],budget:Int)throws->[Embedding]{try embedTexts(paths).map{Embedding(vector:$0,error:nil)}}
        func embedAudio(_ paths:[String])throws->[Embedding]{try embedImages(paths,budget:0)}
        func close(){}
    }
    @Test func inferenceOverlapsWhileOneOwnerCommits()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at:input,withIntermediateDirectories:true)
        for index in 0..<6 {
            try "A searchable document with ordinary words and sentences, number \(index).".write(
                to:input.appendingPathComponent("document-\(index).txt"),atomically:true,encoding:.utf8)
        }
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        let fake=Fake()
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{fake})
        _=try indexer.sync([input])
        let states=try indexer.run()
        #expect(states["done"]==6)
        #expect(fake.peak==3)
        #expect(try store.counts().vectors==6)
    }
    @Test func changedFilesCannotReceivePreparedVectors()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at:input,withIntermediateDirectories:true)
        let file=input.appendingPathComponent("changing.txt")
        try "Original prose for an indexing fixture.".write(to:file,atomically:true,encoding:.utf8)
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        let fake=Fake();fake.change=file
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{fake})
        _=try indexer.sync([input])
        let states=try indexer.run()
        #expect(states["pending"]==1)
        #expect(try store.counts().vectors==0)
        #expect(try store.pendingCount()==1)
    }
    @Test func nestedCommitRollbackDoesNotLoseOuterChanges()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try Database(path:root.appendingPathComponent("fixture.sqlite").path)
        try db.execute("CREATE TABLE fixture(value TEXT)")
        enum Stop:Error{case fixture}
        try db.transaction {
            try db.run("INSERT INTO fixture VALUES(?)",[.text("outer")])
            do{try db.transaction{try db.run("INSERT INTO fixture VALUES(?)",[.text("inner")]);throw Stop.fixture}}catch{}
        }
        var values:[String]=[]
        try db.query("SELECT value FROM fixture"){values.append($0.text(0)!)}
        #expect(values==["outer"])
    }
}
