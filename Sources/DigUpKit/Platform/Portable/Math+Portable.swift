// Host similarity scoring without Accelerate (Linux, Windows). This never performs model inference.
// Generic x64 builds cannot assume F16C: scalar Float16 conversion otherwise makes a library call per element.
#if !canImport(Accelerate)
import CSearchMath

extension Vectors {
    /// Converts `count` float16s into float32s.
    static func floats(fromHalf source: UnsafePointer<Float16>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        source.withMemoryRebound(to: UInt16.self, capacity: count) { halves in
            digup_search_half_to_float(halves, destination, count)
        }
    }

    /// `scores[i]` = the dot product of row `i` of `rows` (`count` rows of `dimension` floats) with `query`.
    static func scores(of rows: UnsafePointer<Float>, count: Int, query: UnsafePointer<Float>,
                       into scores: UnsafeMutablePointer<Float>) {
        let lanes = dimension / 8   // 768 = 96 × 8
        let queryLanes = (0..<lanes).map {
            UnsafeRawPointer(query).loadUnaligned(fromByteOffset: $0 * 32, as: SIMD8<Float>.self)
        }
        for row in 0..<count {
            let start = UnsafeRawPointer(rows + row * dimension)
            var sum = SIMD8<Float>.zero
            for lane in 0..<lanes {
                sum += queryLanes[lane] * start.loadUnaligned(fromByteOffset: lane * 32, as: SIMD8<Float>.self)
            }
            scores[row] = sum.sum()
        }
    }
}
#endif
