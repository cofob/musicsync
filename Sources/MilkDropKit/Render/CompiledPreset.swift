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

    /// Throws when a shader does not translate or compile: such presets are left out, not shown with a stand-in.
    public static func compile(_ preset: Preset, device: MTLDevice, screenFormat: MTLPixelFormat) async throws -> CompiledPreset {
        let warp = try preset.warp.isEmpty ? HLSLTranslator.defaultShader(.warp) : HLSLTranslator.translate(preset.warp, stage: .warp)
        let comp = try preset.comp.isEmpty ? HLSLTranslator.defaultShader(.comp) : HLSLTranslator.translate(preset.comp, stage: .comp)
        async let wp = pipeline(warp, device: device, format: Targets.format)
        async let cp = pipeline(comp, device: device, format: screenFormat)
        return try await CompiledPreset(preset, warp, comp, wp, cp)
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
