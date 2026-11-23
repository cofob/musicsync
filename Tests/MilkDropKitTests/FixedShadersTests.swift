import Metal
@testable import MilkDropKit
import Testing

@Suite struct FixedShadersTests {
    @Test func compilesAndBlurs() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let library = try FixedShaders.library(device: device, extra: [])
        let blur = try #require(Blur(device: device, library: library, size: SIMD2(320, 200)))
        let source = try #require(Targets.texture(device, SIMD2(320, 200)))
        let buffer = try #require(queue.makeCommandBuffer())
        let (mins, maxs) = Blur.ranges([:])
        blur.encode(buffer, source: source, count: 3, mins: mins, maxs: maxs, edgeDarken: 0.25)
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
        #expect(blur.textures.map(\.width) == [80, 32, 16])
    }

    @Test func blurRangesStayApart() {
        let (mins, maxs) = Blur.ranges(["b1n": 0.5, "b1x": 0.5])
        #expect(maxs.x - mins.x >= 0 && mins.x == 0.45)
    }

    @Test func noiseSizes() {
        #expect(Noise.plane(size: 8, zoom: 4).count == 8 * 8 * 4)
        #expect(Noise.volume(size: 8, zoom: 4).count == 8 * 8 * 8 * 4)
    }

    @Test func blendPatternSharesAreInRange() {
        let pattern = BlendPattern(width: 8, height: 6, aspect: SIMD2(1, 0.75))
        #expect((0..<63).allSatisfy { (0...1).contains(pattern.oldShare($0, progress: 0.5)) })
    }
}
