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
    public static func compile(_ preset: Preset, device: MTLDevice, screenFormat: MTLPixelFormat) async throws -> CompiledPreset {
        async let w = stage(preset.warp, .warp, device: device, format: Targets.format)
        async let c = stage(preset.comp, .comp, device: device, format: screenFormat)
        let (warp, comp) = try await (w, c)
        let result = CompiledPreset(preset, warp.shader, comp.shader, warp.pipeline, comp.pipeline)
        result.fallbacks = [warp.error, comp.error].compactMap { $0 }
        return result
    }

    /// Why a stage runs on the default shader ("warp: line 3: …"); empty when both are the preset's own.
    public private(set) var fallbacks: [String] = []

    private static func stage(_ hlsl: String, _ stage: ShaderStage, device: MTLDevice, format: MTLPixelFormat) async throws
        -> (shader: TranslatedShader, pipeline: MTLRenderPipelineState, error: String?) {
        if !hlsl.isEmpty {
            do {
                let shader = try HLSLTranslator.translate(hlsl, stage: stage)
                return (shader, try await pipeline(shader, device: device, format: format), nil)
            } catch {
                let fallback = HLSLTranslator.defaultShader(stage)
                return (fallback, try await pipeline(fallback, device: device, format: format), "\(stage): \(error)")
            }
        }
        let shader = HLSLTranslator.defaultShader(stage)
        return (shader, try await pipeline(shader, device: device, format: format), nil)
    }

    private static func pipeline(_ shader: TranslatedShader, device: MTLDevice, format: MTLPixelFormat) async throws -> MTLRenderPipelineState {
        let library = try await device.makeLibrary(source: shader.source, options: nil)
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
