import Foundation
import Metal

/// A preset with its warp and comp shaders translated and compiled, ready to show. Compiling takes 50–300 ms,
/// so the next preset compiles ahead, off the main thread.
public final class CompiledPreset: @unchecked Sendable {
    public let preset: Preset
    let warp: TranslatedShader, comp: TranslatedShader
    let warpPipeline: MTLRenderPipelineState, compPipeline: MTLRenderPipelineState
    /// Highest blur level the shaders sample.
    var blurLevel: Int { max(warp.blurLevel, comp.blurLevel) }

    private init(_ preset: Preset, _ warp: TranslatedShader, _ comp: TranslatedShader, _ wp: MTLRenderPipelineState, _ cp: MTLRenderPipelineState) {
        self.preset = preset
        self.warp = warp
        self.comp = comp
        warpPipeline = wp
        compPipeline = cp
    }

    /// A shader that does not translate or compile is replaced by the default one of its stage, as MilkDrop does when
    /// D3D rejects it; `fallbacks` says which and why. Throws only when even the default fails (no GPU).
    /// `shaders`: compiled shaders from the preset cache (`PresetCDN`), used instead of compiling when there.
    public static func compile(_ preset: Preset, device: MTLDevice, screenFormat: MTLPixelFormat,
                               shaders: URL? = PresetCDN.shaderFolder) async throws -> CompiledPreset {
        let hash = preset.sourceHash.isEmpty ? nil : preset.sourceHash
        async let w = stage(preset.warp, .warp, hash, shaders, device: device, format: Targets.format)
        async let c = stage(preset.comp, .comp, hash, shaders, device: device, format: screenFormat)
        let (warp, comp) = try await (w, c)
        let result = CompiledPreset(preset, warp.shader, comp.shader, warp.pipeline, comp.pipeline)
        result.fallbacks = [warp.error, comp.error].compactMap { $0 }
        result.prebuilt = [warp, comp].filter(\.prebuilt).count
        return result
    }

    /// Why a stage runs on the default shader ("warp: line 3: …"); empty when both are the preset's own.
    public private(set) var fallbacks: [String] = []
    /// How many stages came compiled from the preset cache.
    public private(set) var prebuilt = 0

    /// `hash`: the preset file's; it names the stage's compiled shader in `shaders` (`<hash>-warp.metallib`, and
    /// `default-warp.metallib` for the default shader).
    private static func stage(_ hlsl: String, _ stage: ShaderStage, _ hash: String?, _ shaders: URL?, device: MTLDevice, format: MTLPixelFormat)
        async throws -> (shader: TranslatedShader, pipeline: MTLRenderPipelineState, error: String?, prebuilt: Bool) {
        func make(_ shader: TranslatedShader, _ name: String?, _ error: String?) async throws
            -> (shader: TranslatedShader, pipeline: MTLRenderPipelineState, error: String?, prebuilt: Bool) {
            let library = name.flatMap { library($0, in: shaders, device: device) }
            return (shader, try await pipeline(shader, library, device: device, format: format), error, library != nil)
        }
        if !hlsl.isEmpty {
            do {
                return try await make(try HLSLTranslator.translate(hlsl, stage: stage), hash.map { "\($0)-\(stage)" }, nil)
            } catch {
                return try await make(HLSLTranslator.defaultShader(stage), "default-\(stage)", "\(stage): \(error)")
            }
        }
        return try await make(HLSLTranslator.defaultShader(stage), "default-\(stage)", nil)
    }

    /// The compiled shader `name` in `folder`; nil when it is not there or does not load.
    private static func library(_ name: String, in folder: URL?, device: MTLDevice) -> MTLLibrary? {
        guard let url = folder?.appendingPathComponent(name + ".metallib"), FileManager.default.fileExists(atPath: url.path),
              let library = try? device.makeLibrary(URL: url), library.functionNames.contains("md_fragment") else { return nil }
        return library
    }

    private static func pipeline(_ shader: TranslatedShader, _ prebuilt: MTLLibrary?, device: MTLDevice, format: MTLPixelFormat) async throws -> MTLRenderPipelineState {
        let library = if let prebuilt { prebuilt } else { try await device.makeLibrary(source: shader.source, options: nil) }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "md_vertex")
        d.fragmentFunction = library.makeFunction(name: "md_fragment")
        d.colorAttachments[0].pixelFormat = format
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try await device.makeRenderPipelineState(descriptor: d)
    }
}
