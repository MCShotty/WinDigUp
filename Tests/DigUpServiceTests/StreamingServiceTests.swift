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
        var startedEmbedding=false
        var discoveryBeforeInferenceFinished=false
        var folders:[String]=[]
        func beginEmbeddingAndWaitForDiscovery() {
            condition.lock();startedEmbedding=true;condition.broadcast()
            let deadline=Date().addingTimeInterval(5)
            while !indexed && condition.wait(until:deadline) {}
            discoveryBeforeInferenceFinished=indexed
            condition.unlock()
        }
        func waitForEmbedding() {
            condition.lock()
            let deadline=Date().addingTimeInterval(5)
            while !startedEmbedding && condition.wait(until:deadline) {}
            condition.unlock()
        }
        func visit(_ folder:URL) {condition.lock();folders.append(folder.path);condition.unlock()}
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
        var before:(()->Void)?
        let info=WorkerInfo(model:"stream-fixture",revision:"fixture",runtime:"fixture",dtype:"fixture",
            dim:768,textOnly:false,loadSeconds:nil)
        func embedTexts(_ values:[String])throws->[[Float]] {before?();return values.map{_ in [1]+[Float](repeating:0,count:767)}}
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

    @Test func ordinaryChangesReconcileTheirSubtreeWithoutRecrawlingASibling() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files")
        let left=files.appendingPathComponent("left"),right=files.appendingPathComponent("right")
        try FileManager.default.createDirectory(at:left,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:right,withIntermediateDirectories:true)
        let changed=left.appendingPathComponent("note.txt")
        try "An original timetable document.".write(to:changed,atomically:false,encoding:.utf8)
        try "A separate useful travel document.".write(to:right.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        let shared=SharedEmbedder{Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let gate=Gate()
        var requested=false
        var service:IndexService?
        service=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),code:nil,
            folder:directory,model:shared,modelReady:{true},backfill:true,newFilesLimit:50,linger:0,
            output:{event in
                if event["event"] as? String=="idle" && !requested {
                    requested=true
                    try? "A revised longer timetable document with meaningful changes.".write(to:changed,atomically:false,encoding:.utf8)
                    let data=try? JSONSerialization.data(withJSONObject:["command":"changes","code":false,
                        "paths":[changed.path],"dirtyRoots":[]])
                    if let data,let line=String(data:data,encoding:.utf8){service?.accept(line)}
                }
            },beforeScanFolder:{gate.visit($0)})
        #expect(service?.serve(commandInput:false)==0)
        #expect(requested)
        #expect(gate.folders.filter{$0==right.path}.count==1)
        #expect(gate.folders.filter{$0==left.path}.count==2)
        #expect(try store.counts().vectors==2)
    }

    @Test func alreadyReadyFileAndCodeQueuesAlternate() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),code=root.appendingPathComponent("code")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:code,withIntermediateDirectories:true)
        for index in 0..<4 {
            try "A useful railway document.".write(to:files.appendingPathComponent("note-\(index).txt"),atomically:false,encoding:.utf8)
            try "def railway():\n    return departure\n".write(to:code.appendingPathComponent("schedule-\(index).py"),atomically:false,encoding:.utf8)
        }
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory),codeStore=try IndexStore(directory:directory,file:IndexStore.codeFile)
        var options=IndexOptions();options.code=true
        let first=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{Model()})
        let second=try Indexer(store:codeStore,options:options,makeEmbedder:{Model()})
        _=try first.sync([files]);_=try second.sync([code])
        var order:[Int]=[]
        _=try Indexer.runScheduled([.init(indexer:first),.init(indexer:second)],onEvent:{source,_,_ in order.append(source)})
        #expect(Array(order.prefix(4))==[0,1,0,1])
    }

    @Test func metadataDiscoveryContinuesWhileInferenceIsBlocked() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),later=files.appendingPathComponent("later")
        try FileManager.default.createDirectory(at:later,withIntermediateDirectories:true)
        for index in 0..<64 {
            try "A useful railway document.".write(to:files.appendingPathComponent("note-\(index).txt"),atomically:false,encoding:.utf8)
        }
        for index in 0..<256 {
            try "A later railway document.".write(to:later.appendingPathComponent("note-\(index).txt"),atomically:false,encoding:.utf8)
        }
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        let gate=Gate()
        let model=Model();model.before={gate.beginEmbeddingAndWaitForDiscovery()}
        let shared=SharedEmbedder{model}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let service=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{true},backfill:true,newFilesLimit:50,linger:0,
            output:{event in
                if (event["event"] as? String=="scan_batch" || event["event"] as? String=="sync"),
                   (event["files"] as? Int ?? 0)>=320 {gate.indexedFile()}
            },beforeScanFolder:{if $0.lastPathComponent=="later"{gate.waitForEmbedding()}})
        #expect(service.serve(commandInput:false)==0)
        #expect(gate.discoveryBeforeInferenceFinished)
        #expect(try store.counts().vectors==320)
    }

}
