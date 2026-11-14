import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// Real-time audio tests: they play or analyze seconds of sound. Run them with MUSICSYNC_SLOW_TESTS=1.
    static var slow: Self {
        .enabled(if: ProcessInfo.processInfo.environment["MUSICSYNC_SLOW_TESTS"] != nil, "slow; set MUSICSYNC_SLOW_TESTS=1")
    }
}
