import Foundation

struct EmbeddingCall: Sendable {
    enum Kind: String, Sendable { case text, image, audio }
    let kind: Kind
    let inputs: [String]
    var budget: Int = 0
}
/// Immutable results cross the inference boundary; replay never invokes the model or owns a database.
final class ComputedEmbedding: Embedder, @unchecked Sendable {
    let info: WorkerInfo
    private struct Key: Hashable { let kind: String;let budget:Int;let input:Data }
    private let values: [Key: Embedding]
    var hasVectors: Bool { values.values.contains { $0.vector != nil } }
    init(calls:[EmbeddingCall],worker:any Embedder)throws {
        info=worker.info
        var values:[Key:Embedding]=[:]
        for call in calls where !call.inputs.isEmpty {
            let embeddings:[Embedding]
            switch call.kind {
            case .text: embeddings=try worker.embedTexts(call.inputs).map{Embedding(vector:$0,error:nil)}
            case .image: embeddings=try worker.embedImages(call.inputs,budget:call.budget)
            case .audio: embeddings=try worker.embedAudio(call.inputs)
            }
            guard embeddings.count==call.inputs.count else{throw WorkerError.failed("Prepared inference returned the wrong result count")}
            for (input,embedding) in zip(call.inputs,embeddings) {
                if let vector=embedding.vector {
                    let norm=vector.reduce(0.0){$0+Double($1)*Double($1)}
                    guard vector.count==768,vector.allSatisfy(\.isFinite),abs(norm-1)<0.005 else{
                        throw WorkerError.failed("Prepared inference returned an invalid vector")
                    }
                }
                values[Key(kind:call.kind.rawValue,budget:call.budget,input:Data(input.utf8))]=embedding
            }
        }
        self.values=values
    }
    private func read(_ kind:EmbeddingCall.Kind,_ inputs:[String],budget:Int=0)throws->[Embedding] {
        try inputs.map{input in
            guard let value=values[Key(kind:kind.rawValue,budget:budget,input:Data(input.utf8))] else{
                throw WorkerError.failed("Commit requested an input absent from its prepared embedding plan")
            }
            return value
        }
    }
    func embedTexts(_ texts:[String])throws->[[Float]] {
        try read(.text,texts).map{embedding in
            guard let vector=embedding.vector else{throw WorkerError.failed(embedding.error ?? "Missing prepared vector")}
            return vector
        }
    }
    func embedImages(_ paths:[String],budget:Int)throws->[Embedding]{try read(.image,paths,budget:budget)}
    func embedAudio(_ paths:[String])throws->[Embedding]{try read(.audio,paths)}
    func close(){}
}
