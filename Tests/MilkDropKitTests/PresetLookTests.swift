import Foundation
@testable import MilkDropKit
import Support
import Testing

@Suite struct PresetLookTests {
    /// A checkerboard of `color` and a darker `color` (by `contrast`).
    private func frame(_ color: SIMD3<Float>, contrast: Float = 0) -> LookFrame {
        LookFrame(width: 8, height: 8) { x, y in (x + y) % 2 == 0 ? color : color * (1 - contrast) }
    }

    private func look(_ color: SIMD3<Float>, contrast: Float = 0) -> PresetLook {
        let still = frame(color, contrast: contrast)
        return PresetLook(shown: [still], kick: (still, still), quiet: (still, still))
    }

    @Test func brightnessSaturationAndWarmth() {
        let warm = look(SIMD3(0.9, 0.4, 0.1)), cold = look(SIMD3(0.1, 0.2, 0.7)), gray = look(SIMD3(0.5, 0.5, 0.5))
        #expect(warm.warmth > 0.5 && cold.warmth < -0.5 && gray.warmth == 0)
        #expect(gray.saturation == 0 && warm.saturation > 0.8)
        #expect(look(SIMD3(0.9, 0.9, 0.9)).brightness > look(SIMD3(0.1, 0.1, 0.1)).brightness + 0.7)
    }

    @Test func contrastIsTheSpreadOfLuma() {
        #expect(look(SIMD3(0.5, 0.5, 0.5)).contrast == 0)
        #expect(abs(look(SIMD3(1, 1, 1), contrast: 1).contrast - 0.5) < 0.01)
    }

    @Test func motionAndBeatReaction() {
        let black = frame(.zero), gray = frame(SIMD3(repeating: 0.2))
        // Still away from the beat, a change across the kick.
        let reacts = PresetLook(shown: [black], kick: (black, gray), quiet: (black, black))
        #expect(reacts.motion == 0 && reacts.beatReaction > 0.95)
        // The same change everywhere: motion, but no reaction to the beat.
        let drifts = PresetLook(shown: [black], kick: (black, gray), quiet: (black, gray))
        #expect(abs(drifts.motion - 0.2) < 0.001 && drifts.beatReaction == 0)
    }

    @Test func moodOrdersBrightWarmBusyOverDarkColdStill() {
        let black = frame(.zero), flash = frame(SIMD3(repeating: 0.3))
        let lively = PresetLook(shown: [frame(SIMD3(1, 0.7, 0.2), contrast: 0.8)], kick: (black, flash), quiet: (black, flash)).mood
        let calm = look(SIMD3(0.02, 0.05, 0.2)).mood
        #expect(lively.arousal > calm.arousal + 0.3 && lively.valence > calm.valence + 0.3)
    }

    @Test func shrinksBGRABytesByBlocks() {
        // 4 × 2 pixels, the left half white, the right half blue (BGRA bytes), shrunk to 2 × 1.
        let white: [UInt8] = [255, 255, 255, 255], blue: [UInt8] = [255, 0, 0, 255]
        let row = white + white + blue + blue
        let small = LookFrame(bgra: row + row, width: 4, height: 2, shrunkTo: SIMD2(2, 1))
        #expect(small.width == 2 && small.height == 1 && small.rgb == [1, 1, 1, 0, 0, 1])
    }
}
