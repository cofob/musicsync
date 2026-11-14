import Foundation
import Testing
@testable import Sync

@Test func junkServerNumbersGiveBoundedSizes() {
    let huge = makeDesired(makeSong("s-1", size: .max, duration: .max, bitRate: .max))
    let negative = makeDesired(makeSong("s-2", size: -5, duration: -1, bitRate: -1))
    let sizes = [huge, negative].map(SizeEstimate.bytes)
    #expect(sizes.allSatisfy { $0 >= 0 && $0 < 1 << 50 })
    #expect(sizes.reduce(0, +) > 0)
}
