import Foundation
import Metal

/// What the preset cache keeps of one preset, made as the app makes it (`PresetPrecompiler`): whether it compiles,
/// its picture and its measures on the demo track.
public final class PresetBaker: @unchecked Sendable {
    public struct Result: Codable, Sendable {
        public var status: PresetCacheManifest.Status
        public var look: PresetLook?
        public var flash: FlashReport?
    }

    private let device: MTLDevice
    private let noise: Noise.Textures?

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        noise = Noise.makeTextures(device: device, queue: queue)
    }

    /// Compiles, renders and measures the preset file `url`; the picture goes to `thumbnail` (JPEG). Blocks a thread
    /// while it renders.
    public func bake(_ url: URL, thumbnail: URL) async -> Result {
        do {
            let preset = try PresetFile.load(url)
            let equations = try PresetEquations(preset, globals: EELGlobals(), frame: FrameGlobals())
            let geometry = try PresetGeometry(preset, globals: EELGlobals(), frame: FrameGlobals())
            let skipped = equations.scope.skipped + geometry.shapes.flatMap(\.eq.scope.skipped) + geometry.waves.flatMap(\.eq.scope.skipped)
            let compiled = try await CompiledPreset.compile(preset, device: device, screenFormat: MilkDropController.screenFormat, shaders: nil)
            let entry = PresetLibrary.Entry(name: preset.name, url: url, isBuiltIn: false, category: "")
            let thumbnails = PresetThumbnails(folder: thumbnail.deletingLastPathComponent())
            try thumbnails.make(compiled, entry: entry, device: device, noise: noise)
            try? FileManager.default.removeItem(at: thumbnail)
            try FileManager.default.moveItem(at: thumbnails.url(entry), to: thumbnail)
            let measure = try PresetMeasurer.measure(compiled, device: device, noise: noise)
            return Result(status: .init(ok: true, fallbacks: compiled.fallbacks, skipped: skipped), look: measure.look, flash: measure.flash)
        } catch {
            return Result(status: .init(ok: false, error: String(describing: error).prefix(600).description))
        }
    }

    /// The MSL of the preset's own shader of `stage`; nil when it runs on the default one (none, or `fallbacks` has it).
    public static func shader(_ preset: Preset, _ stage: ShaderStage, fallbacks: [String]) -> String? {
        let hlsl = stage == .warp ? preset.warp : preset.comp
        guard !hlsl.isEmpty, !fallbacks.contains(where: { $0.hasPrefix("\(stage):") }) else { return nil }
        return try? HLSLTranslator.translate(hlsl, stage: stage).source
    }
}
