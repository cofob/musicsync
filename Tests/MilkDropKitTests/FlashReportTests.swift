import Foundation
@testable import MilkDropKit
import Testing

@Suite struct FlashReportTests {
    /// 4 seconds at 60 fps of 16 × 9 cells; `color(frame, x, y)` is the color of a cell.
    private func clip(_ color: @escaping (Int, Int, Int) -> SIMD3<Float>) -> [LookFrame] {
        (0..<240).map { f in LookFrame(width: 16, height: 9) { x, y in color(f, x, y) } }
    }

    private func gray(_ v: Float) -> SIMD3<Float> { SIMD3(repeating: v) }

    /// On for half of each period, off for the other half, in the cells that `inside` takes.
    private func strobe(hz: Double, on: SIMD3<Float> = SIMD3(repeating: 1), off: SIMD3<Float> = .zero,
                        inside: @escaping (Int, Int) -> Bool = { _, _ in true }) -> [LookFrame] {
        let period = 60 / hz
        return clip { f, x, y in inside(x, y) && Double(f).truncatingRemainder(dividingBy: period) < period / 2 ? on : off }
    }

    @Test func steadyPictureDoesNotFlash() {
        let report = FlashReport(clip { _, _, _ in SIMD3(0.5, 0.4, 0.3) })
        #expect(report.general == 0 && report.red == 0 && report.screen == 0 && report.isSafe)
    }

    @Test func slowFadeIsOneChange() {
        let report = FlashReport(clip { f, _, _ in SIMD3(repeating: Float(f) / 239) })
        #expect(report.general <= 0.5 && report.isSafe)
    }

    @Test func fiveHertzStrobeFails() {
        let report = FlashReport(strobe(hz: 5))
        #expect(report.general >= 4 && !report.isSafe)
    }

    @Test func bigJumpsOfTheWholeScreenFailBeforeTheGeneralLimit() {
        // 2 flashes a second is within the general limit, but of the whole screen at full contrast it is too much.
        let report = FlashReport(strobe(hz: 2))
        #expect(report.general < FlashReport.limits.general && !report.isSafe)
        #expect(FlashReport(strobe(hz: 2, on: gray(0.55), off: gray(0.4))).isSafe)
    }

    @Test func smallFlashingRegionPasses() {
        let small = FlashReport(strobe(hz: 5) { x, y in x < 4 && y < 3 })  // 12 of 144 cells
        #expect(small.general == 0 && small.isSafe)
        let large = FlashReport(strobe(hz: 5) { x, _ in x < 6 })  // 6 of 16 columns
        #expect(large.general >= 4 && !large.isSafe)
    }

    @Test func redFlashFailsWhereBrightnessChangeIsSmall() {
        let report = FlashReport(strobe(hz: 5, on: SIMD3(0.6, 0, 0), off: SIMD3(0.3, 0, 0)))
        #expect(report.general == 0)  // the luminance swing is only 0.05
        #expect(report.red >= 4 && !report.isSafe)
    }

    @Test func flashesAboveTheDarkLimitDoNotCount() {
        // Between 0.95 and 1 gray the darker state is above 0.8 in luminance.
        let report = FlashReport(strobe(hz: 6, on: gray(1), off: gray(0.95)))
        #expect(report.general == 0)
    }

    @Test func swingsCountOnceFromTheStartOfAChange() {
        let ramp = (0..<60).map { Double($0) / 59 }
        #expect(FlashReport.swings(ramp, delta: 0.1).count == 1)
        #expect(FlashReport.swings(ramp + ramp.reversed() + ramp, delta: 0.1).count == 3)
        #expect(FlashReport.swings([0, 0.05, 0.02, 0.06], delta: 0.1).isEmpty)
    }
}
