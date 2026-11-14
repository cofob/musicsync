import Foundation
import Testing
@testable import ITunesDB

/// A fixed-seed generator, so a failing input can be found again.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A damaged iPod database throws; it never traps or loops.
@Test func damagedDatabasesThrowOrParse() throws {
    let good = try sampleDB().serialize()
    var random = SplitMix(state: 58)
    for _ in 0..<3000 {
        var bytes = [UInt8](good)
        for _ in 0..<Int.random(in: 1...6, using: &random) {
            let i = Int.random(in: 0..<bytes.count, using: &random)
            // Mostly the length and count fields: whole 32-bit words of 0, 0xff… or a random value.
            let word = [UInt8](repeating: [0, 0xff, UInt8.random(in: 0...255, using: &random)].randomElement(using: &random) ?? 0, count: 4)
            bytes.replaceSubrange(i..<min(i + 4, bytes.count), with: word)
        }
        if Bool.random(using: &random) { bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &random))) }
        _ = try? ITunesDB.parse(Data(bytes))
        _ = try? PlayCounts.parse(Data(bytes))
    }
}
