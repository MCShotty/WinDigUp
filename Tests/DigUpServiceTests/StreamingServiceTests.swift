import Foundation
import Testing
@testable import DigUpKit
@testable import digup

@Suite(.serialized)
struct StreamingServiceTests {
    func temporary() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return URL(fileURLWithPath:FolderSelection.realPath(root.path),isDirectory:true)
    }
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
        func visit(_ folder:URL) {condition.lock();folders.append(FolderSelection.realPath(folder.path));condition.unlock()}
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
        let root=try temporary()
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
        let root=try temporary()
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
        let root=try temporary()
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
        let root=try temporary()
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
        let root=try temporary()
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

    @Test func committedNamesPublishAfterABurstWhileDiscoveryWaitsWithoutAModel() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),next=files.appendingPathComponent("next")
        let blocked=next.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at:blocked,withIntermediateDirectories:true)
        for folder in [files,next] {
            for ordinal in 0..<64 {
                try "A searchable railway document.".write(to:folder.appendingPathComponent("note-\(ordinal).txt"),
                    atomically:false,encoding:.utf8)
            }
        }
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        var modelStarts=0
        let shared=SharedEmbedder{modelStarts+=1;return Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let gate=Gate()
        var completed=false,publishedBeforeCompletion=false
        let service=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{false},backfill:true,newFilesLimit:50,linger:0,
            output:{event in
                if event["event"] as? String=="sync" {completed=true}
                if event["event"] as? String=="scan_batch" && (event["files"] as? Int)==128 && !completed {
                    #expect(event["namesChanged"] as? Bool==true)
                    publishedBeforeCompletion=true
                    gate.indexedFile()
                }
            },beforeScanFolder:{if $0.lastPathComponent=="blocked" {gate.waitForIndex()}})
        #expect(service.serve(commandInput:false)==0)
        #expect(publishedBeforeCompletion)
        #expect(gate.sawOverlap)
        #expect(modelStarts==0)
        #expect(try store.pendingCount()==128)
        #expect(try store.counts().vectors==0)
    }

    @Test(arguments:[false,true])
    func rescanMetadataFlagsDistinguishUnchangedRowsFromNewAndKindChangedFiles(changed:Bool) throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),blocked=files.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at:blocked,withIntermediateDirectories:true)
        for ordinal in 0..<64 {
            try "A searchable railway document.".write(to:files.appendingPathComponent("note-\(ordinal).txt"),
                atomically:false,encoding:.utf8)
        }
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        var modelStarts=0
        let shared=SharedEmbedder{modelStarts+=1;return Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let seed=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{false},backfill:true,newFilesLimit:50,linger:0,output:{_ in})
        #expect(seed.serve(commandInput:false)==0)
        let original=try #require(try store.files(under:[files.path]).first{URL(fileURLWithPath:$0.path).lastPathComponent=="note-0.txt"})
        if changed {
            // A cached classification can change when current admission rules are applied.
            try store.db.run("UPDATE files SET kind='image' WHERE id=?",[.int(original.id)])
            try "A newly discovered railway document.".write(to:files.appendingPathComponent("new.txt"),atomically:false,encoding:.utf8)
        }
        let gate=Gate()
        let expected=changed ? 65 : 64
        var flags:[Bool]=[]
        let service=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{false},backfill:true,newFilesLimit:50,linger:0,
            output:{event in
                if event["event"] as? String=="scan_batch",let flag=event["namesChanged"] as? Bool {
                    flags.append(flag)
                    if (event["files"] as? Int)==expected {gate.indexedFile()}
                }
            },beforeScanFolder:{if $0.lastPathComponent=="blocked" {gate.waitForIndex()}})
        #expect(service.serve(commandInput:false)==0)
        #expect(gate.sawOverlap)
        #expect(!flags.isEmpty)
        #expect(flags.contains(true)==changed)
        #expect(try store.files(under:[files.path]).first{$0.id==original.id}?.kind == .doc)
        #expect(try store.pendingCount()==expected)
        #expect(try store.counts().vectors==0)
        #expect(modelStarts==0)
    }

    @Test func folderPriorityUsesNativePathSpellingAndSortsDiscoveryRoots() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let first=root.appendingPathComponent("first"),second=root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at:first,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try "An ordinary railway document.".write(to:first.appendingPathComponent("ordinary.txt"),atomically:false,encoding:.utf8)
        try "A preferred railway document.".write(to:second.appendingPathComponent("preferred.txt"),atomically:false,encoding:.utf8)
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        let shared=SharedEmbedder{Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        var order:[String]=[]
        let service=IndexService(main:.init(store:store,indexer:indexer,roots:[first,second],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{true},backfill:true,newFilesLimit:50,linger:0,
            output:{if $0["event"] as? String=="file",let path=$0["path"] as? String {order.append(path)}})
        #if os(Windows)
        let path=second.path.replacingOccurrences(of:"/",with:"\\")
        #else
        let path=second.path
        #endif
        let request=try JSONSerialization.data(withJSONObject:["command":"prioritize","code":false,"path":path])
        service.accept(try #require(String(data:request,encoding:.utf8)))
        #expect(service.serve(commandInput:false)==0)
        #expect(order.first==second.appendingPathComponent("preferred.txt").path)
        #expect(try store.counts().vectors==2)
    }

    @Test func prioritizedSourceYieldsToOtherReadySourcesAfterEightBatches() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),code=root.appendingPathComponent("code")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:code,withIntermediateDirectories:true)
        for index in 0..<24 {
            try "A useful railway document.".write(to:files.appendingPathComponent("note-\(index).txt"),atomically:false,encoding:.utf8)
        }
        for index in 0..<4 {
            try "def railway():\n    return departure\n".write(to:code.appendingPathComponent("schedule-\(index).py"),atomically:false,encoding:.utf8)
        }
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory),codeStore=try IndexStore(directory:directory,file:IndexStore.codeFile)
        var options=IndexOptions();options.code=true
        let first=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{Model()})
        let second=try Indexer(store:codeStore,options:options,makeEmbedder:{Model()})
        _=try first.sync([files]);_=try second.sync([code])
        var order:[Int]=[]
        var prioritySent=false
        _=try Indexer.runScheduled([.init(indexer:first),.init(indexer:second)],onEvent:{source,_,_ in order.append(source)},
            priority:{
                if prioritySent{return nil}
                prioritySent=true
                return (0,files.path)
            })
        #expect(Array(order.prefix(8))==[Int](repeating:0,count:8))
        #expect(order.dropFirst(8).first==1)
        #expect(try store.counts().vectors==24)
        #expect(try codeStore.counts().vectors==4)
    }

    #if !os(Windows)
    @Test(arguments:["blocked","Café"])
    func partialScanHoldsOldPendingRowsAndARecoveredChangeResumesThem(folderName:String) throws {
        let root=try temporary()
        let files=root.appendingPathComponent("files"),blocked=files.appendingPathComponent(folderName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:blocked.path)
            try? FileManager.default.removeItem(at:root)
        }
        try FileManager.default.createDirectory(at:blocked,withIntermediateDirectories:true)
        let good=files.appendingPathComponent("good.txt"),held=blocked.appendingPathComponent("held.txt")
        try "A readable railway document.".write(to:good,atomically:false,encoding:.utf8)
        try "A temporarily inaccessible railway document.".write(to:held,atomically:false,encoding:.utf8)
        let directory=root.appendingPathComponent("index")
        let store=try IndexStore(directory:directory)
        let shared=SharedEmbedder{Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        _=try indexer.sync([files])
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:blocked.path)
        #expect(!FileManager.default.isReadableFile(atPath:blocked.path))
        var requested=false,keptPending=false,knownCount=0,measuredHeld=false
        var service:IndexService?
        service=IndexService(main:.init(store:store,indexer:indexer,roots:[files],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{true},backfill:true,newFilesLimit:50,linger:0,
            output:{event in
                if event["event"] as? String=="idle" && !requested {
                    requested=true
                    let rows=(try? store.files(under:[files.path])) ?? []
                    keptPending=rows.first{$0.path==held.path}?.state=="pending"
                    knownCount=rows.count
                    measuredHeld=(event["held_pending"] as? Int)==1 && (event["runnable_pending"] as? Int)==0
                        && (event["runnable_unfinished"] as? Int)==0
                    try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:blocked.path)
                    let data=try? JSONSerialization.data(withJSONObject:["command":"changes","code":false,
                        "paths":[held.path],"dirtyRoots":[]])
                    if let data,let line=String(data:data,encoding:.utf8) {service?.accept(line)}
                }
            })
        let runningService=service
        let watchdog=DispatchWorkItem {runningService?.accept("stop")}
        DispatchQueue.global().asyncAfter(deadline:.now()+10,execute:watchdog)
        defer {watchdog.cancel()}
        #expect(service?.serve(commandInput:false)==0)
        #expect(requested)
        #expect(keptPending)
        #expect(measuredHeld)
        #expect(knownCount==2)
        #expect(try store.counts().vectors==2)
        #expect(try store.pendingCount()==0)
        #expect(store.pendingExcludedPaths.isEmpty)
    }
    #endif

    func runFolders(_ roots:[URL],index:URL,prune:Bool=true,modelReady:Bool=true) throws -> (events:[[String:Any]],vectors:Int,rows:[FileRecord]) {
        let store=try IndexStore(directory:index)
        let shared=SharedEmbedder{Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        var events:[[String:Any]]=[]
        let service=IndexService(main:.init(store:store,indexer:indexer,roots:roots,keepOnly:prune ? roots : nil),
            code:nil,folder:index,model:shared,modelReady:{modelReady},backfill:true,newFilesLimit:50,linger:0,
            output:{events.append($0)})
        #expect(service.serve(commandInput:false)==0)
        return (events,try store.counts().vectors,try store.files(under:roots.flatMap {[$0.path,$0.resolvingSymlinksInPath().path]}))
    }

    @Test(arguments:[false,true])
    func emptyAndUnavailableScansDoNotRestartDiscoveryAfterCompletion(unavailable:Bool) throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),index=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        if unavailable {
            try "A cached railway document.".write(to:files.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
            #expect(try runFolders([files],index:index).vectors==1)
            try FileManager.default.moveItem(at:files,to:root.appendingPathComponent("away"))
        }
        let result=try runFolders([files],index:index)
        var discoveryActive=false,checkedIdle=false
        for event in result.events {
            if let active=event["discoveryActive"] as? Bool {discoveryActive=active}
            if event["event"] as? String=="idle" {
                checkedIdle=true
                #expect(!discoveryActive)
                #expect(event["files"] as? Int == (unavailable ? 1 : 0))
            }
        }
        #expect(checkedIdle)
    }

    @Test func disconnectedWholeRootKeepsCachedCountsAfterHelperRestart() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),away=root.appendingPathComponent("away")
        let index=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try "A cached railway document.".write(to:files.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        let before=try runFolders([files],index:index)
        #expect(before.vectors==1)
        try FileManager.default.moveItem(at:files,to:away)
        let after=try runFolders([files],index:index)
        let counts=try #require(after.events.last{$0["event"] as? String=="idle"})
        #expect(counts["files"] as? Int==1)
        #expect(counts["searchable"] as? Int==1)
        #expect(counts["known_counts_complete"] as? Bool==true)
        #expect(counts["runnable_pending"] as? Int==0)
        #expect(after.vectors==1)
        let values=["files":counts["files"] ?? 0,"searchable":counts["searchable"] ?? 0,
            "runnable_pending":counts["runnable_pending"] ?? -1,"held_pending":counts["held_pending"] ?? -1]
        let evidence=try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys])
        print("RETAINED_INDEX_EVIDENCE: "+String(decoding:evidence,as:UTF8.self))
    }

    #if !os(Windows)
    #if os(macOS)
    @Test func damagedAliasCachePreservesPrivateVarVectorsForAReadableVarRoot() throws {
        let chosenRoot=URL(fileURLWithPath:"/var/tmp",isDirectory:true)
            .appendingPathComponent("digup-namespace-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:chosenRoot,withIntermediateDirectories:true)
        let root=URL(fileURLWithPath:FolderSelection.realPath(chosenRoot.path),isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        #expect(chosenRoot.path.hasPrefix("/var/tmp/"))
        #expect(root.path.hasPrefix("/private/var/tmp/"))
        let chosen=chosenRoot.appendingPathComponent("files"),files=root.appendingPathComponent("files")
        let index=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try "A retained railway document.".write(to:files.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        let before=try runFolders([chosen],index:index)
        #expect(before.vectors==1)
        let retained=try #require(before.rows.first)
        #expect(retained.path.hasPrefix("/private/var/tmp/"))
        #expect(retained.path==files.appendingPathComponent("note.txt").path)
        let store=try IndexStore(directory:index)
        try store.setMeta("scan_root_aliases_v1","{damaged")
        let after=try runFolders([chosen],index:index,modelReady:false)
        #expect(after.vectors==1)
        #expect(after.rows.count==1)
        #expect(after.rows.first?.state=="done")
        #expect(after.events.allSatisfy{!["file","inference_verified"].contains($0["event"] as? String ?? "")})
        let counts=try #require(after.events.last{$0["event"] as? String=="waiting"})
        #expect(counts["files"] as? Int==1)
        #expect(counts["searchable"] as? Int==1)
        #expect(counts["pending"] as? Int==0)
        #expect(counts["known_counts_complete"] as? Bool==true)
        #expect(try store.counts().vectors==1)
    }
    @Test func damagedAliasCachePreservesComposedDiskNamesAndDecomposedSelection() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let onDisk=root.path+"/Café".precomposedStringWithCanonicalMapping
        #expect(mkdir(onDisk,0o755)==0)
        let chosen=URL(fileURLWithPath:onDisk).standardizedFileURL
        let resolved=try #require(IndexService.resolvedPrunePath(chosen.path))
        #expect(!chosen.path.utf8.elementsEqual(resolved.utf8))
        let resolvedName=String(try #require(resolved.split(separator:"/").last))
        #expect(chosen.lastPathComponent==resolvedName)
        #expect(!chosen.lastPathComponent.utf8.elementsEqual(resolvedName.utf8))
        try "A retained multilingual railway document.".write(to:chosen.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        let index=root.appendingPathComponent("index")
        let before=try runFolders([chosen],index:index)
        #expect(before.vectors==1)
        let retained=try #require(before.rows.first)
        #expect(retained.path.utf8.starts(with:(resolved+"/").utf8))
        let store=try IndexStore(directory:index)
        try store.setMeta("scan_root_aliases_v1","{damaged")
        let after=try runFolders([chosen],index:index,modelReady:false)
        #expect(after.vectors==1)
        #expect(after.rows.count==1)
        #expect(after.rows.first?.state=="done")
        #expect(after.rows.first?.path.utf8.elementsEqual(retained.path.utf8)==true)
        #expect(after.events.allSatisfy { !["file","inference_verified"].contains($0["event"] as? String ?? "") })
        let counts=try #require(after.events.last { $0["event"] as? String=="waiting" })
        #expect(counts["files"] as? Int==1)
        #expect(counts["searchable"] as? Int==1)
        #expect(counts["pending"] as? Int==0)
        #expect(counts["known_counts_complete"] as? Bool==true)
        #expect(try store.counts().vectors==1)
    }
    #endif

    @Test func failedUnicodeChildrenSurviveReportSetCollapseAndRemainHeld() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        let composed=files.path+"/Caf\u{e9}",decomposed=files.path+"/Cafe\u{301}"
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        store.setLiteralScope([files.path])
        for (index,path) in [composed,decomposed].enumerated() {
            _=try store.insert(Candidate(path:path+"/note.txt",kind:.doc,size:10,mtime:1,inode:UInt64(index+1),device:1))
        }
        let shared=SharedEmbedder {Model()}
        let indexer=try Indexer(store:store,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let session=try indexer.beginScan([files])
        defer {session.close()}
        var report=CrawlReport()
        report.recordUnreadable(composed)
        report.recordUnreadable(decomposed)
        #expect(report.unreadable.count==1)
        #expect(report.unreadablePaths.count==2)
        let summary=try session.finish(report)
        #expect(summary.removed==0)
        #expect(session.incompletePrefixes.contains {$0.utf8.elementsEqual(composed.utf8)})
        #expect(session.incompletePrefixes.contains {$0.utf8.elementsEqual(decomposed.utf8)})
        store.pendingExcludedPaths=session.incompletePrefixes
        #expect(try store.pendingCount()==0)
        #expect(try store.counts().byKindAndState["doc"]?["pending"]==2)
        store.pendingExcludedPaths=IndexService.reconcilePendingHolds(store.pendingExcludedPaths,
            completed:[composed],incomplete:[],verifiedRoots:[(chosen:files.path,resolved:files.path)])
        #expect(try store.pendingCount()==1)
        #expect(try store.pending(limit:nil).first?.path.utf8.elementsEqual((composed+"/note.txt").utf8)==true)
        #expect(store.pendingExcludedPaths.contains {$0.utf8.elementsEqual(decomposed.utf8)})
        store.pendingExcludedPaths=IndexService.reconcilePendingHolds(store.pendingExcludedPaths,
            completed:[decomposed],incomplete:[],verifiedRoots:[(chosen:files.path,resolved:files.path)])
        #expect(try store.pendingCount()==2)
        #expect(try store.counts().vectors==0)
    }

    @Test func successfulUnicodeSiblingCannotClearAnUnrelatedFailedRootHold() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let composed="/fixture/Caf\u{e9}",decomposed="/fixture/Cafe\u{301}"
        #expect(composed==decomposed)
        #expect(!IndexStore.literalPathIsUnder(decomposed,composed))
        let store=try IndexStore(directory:root.appendingPathComponent("index"))
        store.setLiteralScope([composed,decomposed])
        for (index,path) in [composed,decomposed].enumerated() {
            _=try store.insert(Candidate(path:path+"/note.txt",kind:.doc,size:10,mtime:1,inode:UInt64(index+1),device:1))
        }
        let held=IndexService.reconcilePendingHolds([decomposed],completed:[composed],incomplete:[],
            verifiedRoots:[(chosen:composed,resolved:composed)])
        #expect(held.count==1)
        #expect(held.first?.utf8.elementsEqual(decomposed.utf8)==true)
        store.pendingExcludedPaths=held
        #expect(try store.pendingCount()==1)
        #expect(try store.pending(limit:nil).first?.path.utf8.elementsEqual((composed+"/note.txt").utf8)==true)
        store.pendingExcludedPaths=IndexService.reconcilePendingHolds(held,completed:[decomposed],incomplete:[],
            verifiedRoots:[(chosen:decomposed,resolved:decomposed)])
        #expect(store.pendingExcludedPaths.isEmpty)
        #expect(try store.pendingCount()==2)
    }

    @Test func onlyVerifiedAliasesClearOrRestoreBothPendingHoldNamespaces() throws {
        let raw="/selection/chosen",resolved="/disk/Café",failed=resolved+"/blocked"
        let rawHold=raw+"/blocked"
        let unmapped=IndexService.reconcilePendingHolds([rawHold,failed],completed:[resolved],incomplete:[],verifiedRoots:[])
        #expect(unmapped==[rawHold])
        let mapping=[(chosen:raw,resolved:resolved)]
        let recovered=IndexService.reconcilePendingHolds([rawHold,failed],completed:[resolved],incomplete:[],verifiedRoots:mapping)
        #expect(recovered.isEmpty)
        let partial=IndexService.reconcilePendingHolds([rawHold,failed],completed:[resolved],incomplete:[failed],verifiedRoots:mapping)
        #expect(Set(partial.map {Data($0.utf8)})==Set([Data(rawHold.utf8),Data(failed.utf8)]))
    }

    @Test(arguments:["disappeared","retargeted","captured"])
    func pruningUsesOneValidatedNamespaceSnapshotWithoutFollowingChangedRoots(change:String) throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let first=root.appendingPathComponent("first"),second=root.appendingPathComponent("second")
        let chosen=root.appendingPathComponent("chosen"),index=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:first,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try "A retained railway document.".write(to:first.appendingPathComponent("old.txt"),atomically:false,encoding:.utf8)
        try "A different unselected document.".write(to:second.appendingPathComponent("new.txt"),atomically:false,encoding:.utf8)
        try FileManager.default.createSymbolicLink(at:chosen,withDestinationURL:first)
        #expect(try runFolders([chosen],index:index).vectors==1)
        let previous=try #require(IndexService.resolvedPrunePath(chosen.path))
        var resolutions=0
        let namespaces=IndexService.validatedPruneNamespaces(roots:[chosen],
            aliases:[Data(chosen.path.utf8).base64EncodedString():previous],requiresLiteral:false,resolve:{path in
                resolutions+=1
                if change != "captured" {
                    try? FileManager.default.removeItem(at:chosen)
                    if change=="retargeted" {try? FileManager.default.createSymbolicLink(at:chosen,withDestinationURL:second)}
                }
                return IndexService.resolvedPrunePath(path)
            })
        #expect(resolutions==1)
        let store=try IndexStore(directory:index)
        if change=="captured" {
            let snapshot=try #require(namespaces)
            #expect(snapshot.contains { $0.utf8.elementsEqual(previous.utf8) })
            try FileManager.default.removeItem(at:chosen)
            try FileManager.default.createSymbolicLink(at:chosen,withDestinationURL:second)
            #expect(try store.prune(keepingUnder:snapshot,literalPaths:true)==0)
        } else {
            #expect(namespaces==nil)
        }
        let after=try runFolders([chosen],index:index,modelReady:false)
        #expect(try store.counts().vectors==1)
        #expect(try store.files(under:[first.path]).count==1)
        #expect(try store.files(under:[second.path]).isEmpty)
        #expect(after.events.allSatisfy { !["file","inference_verified"].contains($0["event"] as? String ?? "") })
    }

    @Test func rootAliasCacheIsIsolatedVersionedAndRecoversFromCorruption() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),alias=root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try "An isolated railway document.".write(to:files.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:files)
        let first=root.appendingPathComponent("index-one"),second=root.appendingPathComponent("index-two")
        _=try runFolders([alias],index:first)
        let secondStore=try IndexStore(directory:second)
        #expect(try secondStore.meta("scan_root_aliases_v1")==nil)
        try secondStore.setMeta("scan_root_aliases_v1","{damaged")
        let held=try runFolders([alias],index:second)
        #expect(held.vectors==0)
        #expect(held.events.contains{$0["event"] as? String=="source_unavailable"})
        let repaired=try runFolders([files],index:second)
        #expect(repaired.vectors==1)
        let text=try #require(try secondStore.meta("scan_root_aliases_v1"))
        let data=try #require(text.data(using:.utf8))
        let cache=try #require(try JSONSerialization.jsonObject(with:data) as? [String:Any])
        #expect(cache["schemaVersion"] as? Int==1)
        try secondStore.setMeta("scan_root_aliases_v1","{\"schemaVersion\":99,\"roots\":{}}")
        _=try runFolders([files],index:second)
        let updated=try #require(try secondStore.meta("scan_root_aliases_v1"))
        #expect(updated.contains("\"schemaVersion\":1"))
        let missing=root.appendingPathComponent("missing")
        let unrelated=try runFolders([missing],index:second)
        let counts=try #require(unrelated.events.last{$0["event"] as? String=="idle"})
        #expect(counts["known_counts_complete"] as? Bool==false)
        let cleaned=try #require(try secondStore.meta("scan_root_aliases_v1"))
        let cleanedData=try #require(cleaned.data(using:.utf8))
        let cleanedCache=try #require(try JSONSerialization.jsonObject(with:cleanedData) as? [String:Any])
        let cleanedRoots=try #require(cleanedCache["roots"] as? [String:String])
        #expect(cleanedRoots[Data(alias.path.utf8).base64EncodedString()]==nil)
    }

    @Test func changedSymlinkTargetIsHeldInsteadOfFollowingANewFolder() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let first=root.appendingPathComponent("first"),second=root.appendingPathComponent("second")
        let alias=root.appendingPathComponent("chosen"),index=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:first,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try "A previously selected railway document.".write(to:first.appendingPathComponent("old.txt"),atomically:false,encoding:.utf8)
        try "A different unselected railway document.".write(to:second.appendingPathComponent("new.txt"),atomically:false,encoding:.utf8)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:first)
        #expect(try runFolders([alias],index:index).vectors==1)
        try FileManager.default.removeItem(at:alias)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:second)
        let after=try runFolders([alias],index:index)
        #expect(after.vectors==1)
        #expect(after.events.contains{$0["event"] as? String=="source_unavailable"})
        let store=try IndexStore(directory:index)
        #expect(try store.files(under:[second.path]).isEmpty)
        #expect(try store.files(under:[first.path]).count==1)
        let data=try #require(try store.meta("scan_root_aliases_v1"))
        let encoded=try #require(data.data(using:.utf8))
        let cache=try #require(try JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        let cachedRoots=try #require(cache["roots"] as? [String:String])
        #expect(cachedRoots[Data(alias.path.utf8).base64EncodedString()]==first.path)
    }

    @Test func damagedAliasCacheAndMissingRootKeepVectorsWithoutGuessingCoverage() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let target=root.appendingPathComponent("target"),alias=root.appendingPathComponent("chosen")
        let index=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        try "A retained railway document.".write(to:target.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:target)
        #expect(try runFolders([alias],index:index).vectors==1)
        try FileManager.default.removeItem(at:alias)
        let corrupt=try IndexStore(directory:index)
        try corrupt.setMeta("scan_root_aliases_v1","{damaged")
        let after=try runFolders([alias],index:index)
        let counts=try #require(after.events.last{$0["event"] as? String=="idle"})
        #expect(counts["known_counts_complete"] as? Bool==false)
        let unscoped=try IndexStore(directory:index)
        #expect(try unscoped.counts().vectors==1)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:target)
        let stillUnknown=try runFolders([alias],index:index)
        #expect(stillUnknown.events.contains{$0["event"] as? String=="source_unavailable"})
        let recovered=try runFolders([target],index:index)
        #expect(recovered.vectors==1)
        let ready=try #require(recovered.events.last{$0["event"] as? String=="idle"})
        #expect(ready["known_counts_complete"] as? Bool==true)
    }

    @Test func aliasMetadataRejectsStaleWritersAndMergesIndependentOwners() throws {
        let root=try temporary()
        defer {try? FileManager.default.removeItem(at:root)}
        let files=root.appendingPathComponent("files"),other=root.appendingPathComponent("other")
        let directory=root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at:files,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try "A railway document for the metadata ownership fixture.".write(to:files.appendingPathComponent("note.txt"),atomically:false,encoding:.utf8)
        let owner=try IndexStore(directory:directory),concurrent=try IndexStore(directory:directory)
        let shared=SharedEmbedder{Model()}
        let indexer=try Indexer(store:owner,options:IndexOptions(),makeEmbedder:{try shared.embedder()})
        let payload=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"roots":[
            Data(other.path.utf8).base64EncodedString():other.path]],options:[.sortedKeys])
        let external=try #require(String(data:payload,encoding:.utf8))
        let gate=Gate()
        var requestAgain=false
        var service:IndexService?
        service=IndexService(main:.init(store:owner,indexer:indexer,roots:[files],keepOnly:nil),
            code:nil,folder:directory,model:shared,modelReady:{true},backfill:true,newFilesLimit:50,linger:0,
            output:{event in
                if event["event"] as? String=="sync" && !requestAgain {
                    requestAgain=true
                    try? concurrent.setMeta("scan_root_aliases_v1",external)
                    service?.accept("sync")
                }
            },beforeScanFolder:{gate.visit($0)})
        #expect(service?.serve(commandInput:false)==0)
        #expect(try concurrent.meta("scan_root_aliases_v1")==external)
        #expect(try owner.counts().vectors==1)
        _=try runFolders([files],index:directory,prune:false)
        let text=try #require(try concurrent.meta("scan_root_aliases_v1"))
        let data=try #require(text.data(using:.utf8))
        let cache=try #require(try JSONSerialization.jsonObject(with:data) as? [String:Any])
        let records=try #require(cache["roots"] as? [String:String])
        #expect(records[Data(other.path.utf8).base64EncodedString()]==other.path)
        #expect(records[Data(files.path.utf8).base64EncodedString()]==files.path)
    }
    #endif

}
