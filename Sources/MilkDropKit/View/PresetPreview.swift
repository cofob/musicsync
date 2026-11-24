import Foundation
import MetalKit

/// One preset, live on the music that plays, for the preset browser's hover preview. Each preset starts from
/// black, as it would when chosen.
@MainActor public final class PresetPreview: MilkDropDrawing {
    /// The samples that play now and their rate; the demo track when nil.
    public var samples: (() -> (left: [Float], right: [Float], rate: Double))?
    public private(set) var shown: String?
    private var compiled: CompiledPreset?
    private var renderer: Renderer?
    private var fresh = false
    private var task: Task<Void, Never>?
    private var noise: Noise.Textures?
    private var frame = 0
    private let start = ContinuousClock.now

    static let renderSize = SIMD2(960, 540)

    public init() {}

    /// Starts showing `entry` once it has compiled (at once when the shader cache has it); nil stops.
    public func show(_ entry: PresetLibrary.Entry?) {
        guard entry?.name != shown else { return }
        shown = entry?.name
        task?.cancel()
        compiled = nil
        guard let entry, let device = MTLCreateSystemDefaultDevice() else { return }
        task = Task {
            let result = try? await CompiledPreset.compile(PresetFile.load(entry.url), device: device, screenFormat: MilkDropController.screenFormat)
            guard !Task.isCancelled, shown == entry.name else { return }
            compiled = result
            fresh = true
        }
    }

    public func draw(in view: MTKView) {
        guard let device = view.device, let compiled else { return }
        if fresh {
            if noise == nil, let queue = device.makeCommandQueue() { noise = Noise.makeTextures(device: device, queue: queue) }
            renderer = Renderer(device: device, noise: noise)
            try? renderer?.show(compiled, blend: 0)
            fresh = false
            frame = 0
        }
        guard let renderer, let drawable = view.currentDrawable, let buffer = renderer.queue.makeCommandBuffer() else { return }
        frame += 1
        let demo = DemoTrack.samples(frame: frame)
        let audio = samples?() ?? (left: demo, right: demo, rate: DemoTrack.rate)
        // At the size the visualizer renders, not the card's: presets move by fractions of a pixel per frame and
        // look different, and step, on a small target. The comp pass scales it down into the card.
        let size = Self.renderSize
        let d = ContinuousClock.now - start
        renderer.render(into: drawable.texture, buffer: buffer, size: size, left: audio.left, right: audio.right, sampleRate: audio.rate,
                        now: Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
        buffer.present(drawable)
        buffer.commit()
    }

    public func sizeChanged(_ size: CGSize, in view: MTKView) {}
}
