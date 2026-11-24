import Metal
@testable import MilkDropKit
import Testing

@Suite struct BrightnessLimiterTests {
    /// Shows a frame of one gray `value` through the limiter; returns the screen's mean brightness 0…1.
    static func show(_ value: Double, _ limiter: BrightnessLimiter, _ device: MTLDevice, _ queue: MTLCommandQueue, _ screen: MTLTexture) throws -> Double {
        let frame = try #require(limiter.frame(like: screen, device: device))
        let buffer = try #require(queue.makeCommandBuffer())
        let d = MTLRenderPassDescriptor()
        (d.colorAttachments[0].texture, d.colorAttachments[0].loadAction, d.colorAttachments[0].storeAction) = (frame, .clear, .store)
        d.colorAttachments[0].clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: d)?.endEncoding()
        limiter.encode(buffer, into: screen, dt: 1.0 / 60)
        buffer.commit()
        buffer.waitUntilCompleted()
        return RendererTests.brightness(screen) / 255
    }

    @Test func flashBecomesFade() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let screen = RendererTests.screen(device) else { return }
        let library = try FixedShaders.library(device: device, extra: [])
        let limiter = try #require(BrightnessLimiter(device: device, library: library, format: .bgra8Unorm))
        let step = Double(BrightnessLimiter.rate) / 60
        #expect(try Self.show(0, limiter, device, queue, screen) < 0.01)  // the first frame shows as it is
        #expect(abs(try Self.show(1, limiter, device, queue, screen) - step) < 0.01)  // white: one step brighter
        #expect(abs(try Self.show(0, limiter, device, queue, screen)) < 0.01)  // back to black is within a step
        var level = 0.0
        for _ in 0..<90 { level = try Self.show(1, limiter, device, queue, screen) }
        #expect(level > 0.99)  // a lasting change arrives
        limiter.reset()
        #expect(try Self.show(0, limiter, device, queue, screen) < 0.01)  // after a reset, at once
    }
}
