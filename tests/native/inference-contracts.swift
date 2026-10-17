import CGPUAdmission
import Foundation

public struct WorkerInfo: Sendable {
    var vectorSource="fixture"
    var backend:String?="fixture"
    var deviceId:String?="fixture-device"
    var device:String?="Fixture accelerator"
}
public enum WorkerError:Error,CustomStringConvertible {
    case failed(String)
    public var description:String{switch self{case .failed(let text):text}}
}
public struct Embedding:Sendable {
    let vector:[Float]?
    let error:String?
}
public protocol Embedder:AnyObject {
    var info:WorkerInfo{get}
    func embedTexts(_ texts:[String])throws->[[Float]]
    func embedImages(_ paths:[String],budget:Int)throws->[Embedding]
    func embedAudio(_ paths:[String])throws->[Embedding]
    func close()
}
enum AppPaths {
    static var defaultIndex:URL{FileManager.default.temporaryDirectory.appendingPathComponent("digup-test-default/index")}
}
final class Counter:@unchecked Sendable {
    let lock=NSCondition()
    var active=0,maximum=0,calls:[[String]]=[]
    var entered=0
    func begin(_ inputs:[String]) {
        lock.lock();active+=1;entered+=1;maximum=max(maximum,active);calls.append(inputs)
        lock.broadcast()
        let until=Date().addingTimeInterval(0.3)
        while active<3 && Date()<until{_ = lock.wait(until:until)}
        lock.unlock()
        Thread.sleep(forTimeInterval:0.02)
    }
    func end(){lock.lock();active-=1;lock.broadcast();lock.unlock()}
}
final class Fake:Embedder,@unchecked Sendable {
    let counter:Counter
    let info=WorkerInfo()
    init(_ counter:Counter){self.counter=counter}
    func embedTexts(_ texts:[String])throws->[[Float]] {
        counter.begin(texts);defer{counter.end()}
        return texts.map{_ in [Float(1)]+[Float](repeating:0,count:767)}
    }
    func embedImages(_ paths:[String],budget:Int)throws->[Embedding]{try embedTexts(paths).map{Embedding(vector:$0,error:nil)}}
    func embedAudio(_ paths:[String])throws->[Embedding]{try embedImages(paths,budget:0)}
    func close(){}
}
@main struct Contracts {
    static func main()throws {
        let args=CommandLine.arguments
        if args.count==3,args[1]=="--hold" {
            guard let lease=args[2].withCString({digup_lease_try($0,0)})else{exit(2)}
            FileHandle.standardOutput.write(Data("ready\n".utf8))
            Thread.sleep(forTimeInterval:60)
            digup_lease_release(lease)
            return
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("digup-admission-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let gate=try GPUAdmission(identity:"fixture",maximum:3,root:root)
        let a=try gate.request(profile:"fixture",foreground:false,timeout:1)
        let b=try gate.request(profile:"fixture",foreground:false,timeout:1)
        let c=try gate.request(profile:"fixture",foreground:false,timeout:1)
        do{
            _=try gate.request(profile:"fixture",foreground:false,timeout:0.03)
            fatalError("A fourth job bypassed the shared device limit")
        }catch{}
        a.finish();b.finish();c.finish()
        let holder=root.appendingPathComponent("crash.lock").path
        let child=Process(),out=Pipe()
        child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments=["--hold",holder];child.standardOutput=out
        try child.run()
        let data=out.fileHandleForReading.availableData
        precondition(String(decoding:data,as:UTF8.self).contains("ready"))
        precondition(holder.withCString{digup_lease_try($0,0)}==nil)
        child.terminate();child.waitUntilExit()
        let released=holder.withCString{digup_lease_try($0,0)}
        precondition(released != nil,"A killed process retained its lease")
        digup_lease_release(released)
        let foreground=try GPUAdmission(identity:"priority",maximum:1,root:root)
        let front=try foreground.request(profile:"query",foreground:true,timeout:1)
        do{
            _=try foreground.request(profile:"document",foreground:false,timeout:0.03)
            fatalError("Background inference passed a foreground request")
        }catch{}
        front.finish()
        let start=ProcessInfo.processInfo.systemUptime
        let background=try foreground.request(profile:"document",foreground:false,timeout:2)
        precondition(ProcessInfo.processInfo.systemUptime-start>=0.95)
        background.finish()
        let count=Counter()
        let pool=try EmbeddingPool(maximum:3){Fake(count)}
        let group=DispatchGroup()
        for index in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                defer{group.leave()}
                let values=try! pool.embedTexts([String(repeating:"x",count:9000)+String(index)])
                precondition(values.count==1 && values[0].count==768)
            }
        }
        precondition(group.wait(timeout:.now()+5) == .success)
        precondition(count.maximum==3,"Three independent model owners did not overlap")
        pool.close()
        let vectors=try ComputedEmbedding(calls:[EmbeddingCall(kind:.text,inputs:["prepared"])],worker:Fake(Counter()))
        let replayed=try vectors.embedTexts(["prepared"])
        precondition(replayed.first?.first==1)
        do{_ = try vectors.embedTexts(["stale"]);fatalError("Commit inferred an unprepared input")}catch{}
        print("Admission: global bound, crash release, foreground priority, quiet resumption; pool: three owners; commit: prepared inputs only. Synthetic vectors, no hardware inference.")
    }
}
