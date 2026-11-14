import Foundation

/// SplitMix64: the same seed always gives the same numbers, so a mix of the day stays the same all day.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    /// Seed from text (FNV-1a). `Hasher` is not used: it changes on every launch.
    public init(_ text: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        self.init(seed: hash)
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1].
    mutating func unit() -> Double { Double(next() >> 11 + 1) / Double(1 << 53) }

    /// Random order where items with higher `weight` tend to come first (Efraimidis–Spirakis).
    mutating func weightedShuffle<T>(_ items: [T], weight: (T) -> Double) -> [T] {
        items.map { item in (item, log(unit()) / max(weight(item), 1e-6)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
