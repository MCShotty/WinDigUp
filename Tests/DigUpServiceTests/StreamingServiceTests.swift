import Foundation
import Testing
import DigUpKit
@testable import digup

@Suite(.serialized)
struct StreamingServiceTests {
    final class Gate:@unchecked Sendable {
        let condition=NSCondition()
        var indexed=false
        var sawOverlap=false
        func waitForIndex() {
            condition.lock()
            let deadline=Date().addingTimeInterval(5)
            while !indexed && condition.wait(until:deadline) {}
            sawOverlap=indexed
            condition.unlock()
        }
        func indexedFile() {
            condition.lock();indexed=true;condition.broadcast();condition.unlock()
        }
    }
    final class Model:Embedder {
        let info=WorkerInfo(model:"stream-fixture",revision:"fixture",runtime:"fixture",dtype:"fixture",
            dim:768,textOnly:false,loadSeconds:nil)
        func embedTexts(_ values:[String])throws->[[Float]] {values.map{_ in [1]+[Float](repeating:0,count:767)}}
        func embedImages(_ paths:[String],budget:Int)throws->[Embedding] {try embedTexts(paths).map{Embedding(vector:$0,error:nil)}}
        func embedAudio(_ paths:[String])throws->[Embedding] {try embedImages(paths,budget:0)}
        func close(){}
    }

    @Test func firstFileIndexesWhileTheNextFolderIsStillBeingDiscovered() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files")
        let child=files.appendingPathComponent("later")
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        for index in 0..<64 {
            try "A meaningful document about a railway journey.".write(to:files.appendingPathComponent("note-\(index).txt"),
                atomically:false,encoding:.utf8)
        }
        try "Later content with useful words.".write(to:child.appendingPathComponent("later.txt"),atomically:false,encoding:.utf8)
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        let gate=Gate()
        let shared=SharedEmbedder{Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let service=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{true},backfill:true,newFilesLimit:50,linger:0,
            output:{if $0["event"] as? String=="file"{gate.indexedFile()}},
            beforeScanFolder:{if $0.lastPathComponent=="later"{gate.waitForIndex()}})
        #expect(service.serve(commandInput:false)==0)
        #expect(gate.sawOverlap)
        #expect(try store.counts().vectors==65)
    }
    @Test func slowCodeDiscoveryCannotBlockReadyFileInference() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),code=root.appendingPathComponent("code")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:code,withIntermediateDirectories:true)
        try "A useful railway document.".write(to:files.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        try "def railway():\n    return departure\n".write(to:code.appendingPathComponent("schedule.py"),atomically:false,encoding:.utf8)
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        let codeStore=try IndexStore(directory:directory,file:IndexStore.codeFile)
        var options=IndexOptions();options.code=true
        let gate=Gate()
        let shared=SharedEmbedder{Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let codeIndexer=try Indexer(store:codeStore,options:options,makeEmbedder:{try shared.embedder()})
        let service=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),
            code:.init(store:codeStore,indexer:codeIndexer,roots:[code],keepOnly:nil),
            folder:directory,model:shared,modelReady:{true},backfill:true,newFilesLimit:50,linger:0,
            output:{if $0["event"] as? String=="file" && $0["code"] as? Bool==false {gate.indexedFile()}},
            beforeScanFolder:{if $0.lastPathComponent=="code"{gate.waitForIndex()}})
        #expect(service.serve(commandInput:false)==0)
        #expect(gate.sawOverlap)
        #expect(try store.counts().vectors==1)
        #expect(try codeStore.counts().vectors==1)
    }

}
