import Foundation

/// EEL math with butterchurn's rules for the edge cases.
enum EELMath {
    /// Values closer than this are equal; a value closer than this to 0 is false.
    static let epsilon = 0.00001

    @inline(__always) static func isTrue(_ x: Double) -> Bool { abs(x) > epsilon }
    @inline(__always) static func bool(_ b: Bool) -> Double { b ? 1 : 0 }

    @inline(__always) static func div(_ a: Double, _ b: Double) -> Double { b == 0 ? 0 : a / b }

    @inline(__always) static func mod(_ a: Double, _ b: Double) -> Double {
        let d = b.rounded(.down)
        return d == 0 ? 0 : fmod(a.rounded(.down), d)
    }

    @inline(__always) static func pow(_ a: Double, _ b: Double) -> Double {
        let p = Foundation.pow(a, b)
        return p.isFinite ? p : 0
    }

    @inline(__always) static func sigmoid(_ a: Double, _ b: Double) -> Double {
        let t = 1 + exp(-a * b)
        return abs(t) > epsilon ? 1 / t : 0
    }

    @inline(__always) static func sign(_ x: Double) -> Double { x > 0 ? 1 : x < 0 ? -1 : 0 }

    /// `floor(random * floor(n))`; for `n < 1` just `random`.
    @inline(__always) static func rand(_ n: Double, _ random: () -> Double) -> Double {
        let m = n.rounded(.down)
        return m < 1 ? random() : (random() * m).rounded(.down)
    }

    /// JavaScript's `Math.floor(x) | 0`: floor, then wrap to Int32; NaN and infinity give 0.
    @inline(__always) static func int32(_ x: Double) -> Int32 {
        guard x.isFinite else { return 0 }
        return Int32(truncatingIfNeeded: Int64(fmod(x.rounded(.down), 4_294_967_296)))
    }
}
