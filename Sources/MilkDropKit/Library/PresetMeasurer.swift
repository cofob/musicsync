import Foundation
import Metal
import Support

/// What is known about a preset from rendering it on the demo track: how it looks and how it flashes.
public struct PresetMeasure: Codable, Equatable, Sendable {
    public var look: PresetLook
    public var flash: FlashReport

    public var mood: Mood { look.mood }
}

/// Renders a preset on the demo track for four seconds at 60 fps, from its start, and measures its frames.
enum PresetMeasurer {
    static let size = SIMD2(320, 180)
    static let frames = 240
    /// The demo track's kick is on every 30th frame. Frames 207 and 213 are around the kick at 210; 216 and 222 are
    /// as far apart, between kicks. The colors are judged on the last frames.
    static let kick = (207, 213), quiet = (216, 222), shown = [213, 222, 239]

    /// Blocks the calling thread.
    static func measure(_ compiled: CompiledPreset, device: MTLDevice, noise: Noise.Textures?) throws -> PresetMeasure {
        guard let renderer = Renderer(device: device, noise: noise) else { throw CocoaError(.featureUnsupported) }
        let (w, h) = (size.x, size.y)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MilkDropController.screenFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let screen = device.makeTexture(descriptor: d) else { throw CocoaError(.featureUnsupported) }
        try renderer.show(compiled, blend: 0)
        var pictures: [LookFrame] = []
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for f in 0..<frames {
            guard let buffer = renderer.queue.makeCommandBuffer() else { throw CocoaError(.featureUnsupported) }
            let a = DemoTrack.samples(frame: f)
            renderer.render(into: screen, buffer: buffer, size: size, left: a, right: a, sampleRate: DemoTrack.rate, now: Double(f) / 60)
            buffer.commit()
            buffer.waitUntilCompleted()
            screen.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            pictures.append(LookFrame(bgra: bytes, width: w, height: h))
        }
        return measure(pictures)
    }

    /// From the frames of the clip.
    static func measure(_ pictures: [LookFrame]) -> PresetMeasure {
        PresetMeasure(look: PresetLook(shown: shown.map { pictures[$0] }, kick: (pictures[kick.0], pictures[kick.1]),
                                       quiet: (pictures[quiet.0], pictures[quiet.1])),
                      flash: FlashReport(pictures))
    }
}
