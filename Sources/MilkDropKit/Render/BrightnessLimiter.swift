import Metal

/// Turns sudden jumps of the picture's brightness into short fades, for viewers sensitive to flashing. The mean
/// brightness of the shown picture changes at most `rate` a second: when a frame's mean is further off, the frame
/// shows mixed with the last shown one. All on the GPU, so the first frame of a flash is already eased.
final class BrightnessLimiter {
    /// Most change of the mean brightness (0…1) in a second. A full-screen swing of 0.25 then takes 0.3 s, so the
    /// picture cannot make the two such swings a second that `FlashReport` allows.
    static let rate: Float = 0.8

    private let level: MTLRenderPipelineState, output: MTLRenderPipelineState
    /// The frame as drawn, before the limit; mipmapped, so its 1 × 1 level is the mean.
    private(set) var frame: MTLTexture?
    /// The last shown picture and the next one.
    private var history: [MTLTexture] = []
    /// Mean brightness of the last shown picture (r), share of the new frame (g), 1 once there is a picture (b).
    private var levels: [MTLTexture] = []

    init?(device: MTLDevice, library: MTLLibrary, format: MTLPixelFormat) {
        func pipeline(_ name: String, _ formats: [MTLPixelFormat]) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "md_quad")
            d.fragmentFunction = library.makeFunction(name: name)
            for (i, f) in formats.enumerated() { d.colorAttachments[i].pixelFormat = f }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let level = pipeline("md_limit_level", [.rgba32Float]), let output = pipeline("md_limit", [format, format]) else { return nil }
        self.level = level
        self.output = output
    }

    /// The texture to draw the frame into, sized like `screen`. A new size starts again without a last picture.
    func frame(like screen: MTLTexture, device: MTLDevice) -> MTLTexture? {
        if let frame, frame.width == screen.width, frame.height == screen.height { return frame }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: screen.pixelFormat, width: screen.width, height: screen.height, mipmapped: true)
        (d.usage, d.storageMode) = ([.renderTarget, .shaderRead], .private)
        frame = device.makeTexture(descriptor: d)
        d.mipmapLevelCount = 1
        history = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        let l = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        (l.usage, l.storageMode) = ([.renderTarget, .shaderRead], .private)
        levels = (0..<2).compactMap { _ in device.makeTexture(descriptor: l) }
        guard history.count == 2, levels.count == 2 else { frame = nil; return nil }
        reset()
        return frame
    }

    /// Forgets the last picture: the next frame shows as it is.
    func reset() { cleared = false }
    private var cleared = false

    /// Shows `frame` on `screen`, limited; `dt`: seconds since the last frame.
    func encode(_ buffer: MTLCommandBuffer, into screen: MTLTexture, dt: Double) {
        guard let frame, history.count == 2, levels.count == 2 else { return }
        if !cleared {
            cleared = true
            for texture in levels {
                let d = MTLRenderPassDescriptor()
                (d.colorAttachments[0].texture, d.colorAttachments[0].loadAction, d.colorAttachments[0].storeAction) = (texture, .clear, .store)
                d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                buffer.makeRenderCommandEncoder(descriptor: d)?.endEncoding()
            }
        }
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: frame)
            blit.endEncoding()
        }
        var step = Self.rate * Float(min(max(dt, 0), 0.1))
        let d = MTLRenderPassDescriptor()
        (d.colorAttachments[0].texture, d.colorAttachments[0].loadAction, d.colorAttachments[0].storeAction) = (levels[1], .dontCare, .store)
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: d) {
            encoder.setRenderPipelineState(level)
            encoder.setFragmentTexture(frame, index: 0)
            encoder.setFragmentTexture(levels[0], index: 1)
            encoder.setFragmentBytes(&step, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        let o = MTLRenderPassDescriptor()
        for (i, texture) in [screen, history[1]].enumerated() {
            (o.colorAttachments[i].texture, o.colorAttachments[i].loadAction, o.colorAttachments[i].storeAction) = (texture, .dontCare, .store)
        }
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: o) {
            encoder.setRenderPipelineState(output)
            encoder.setFragmentTexture(frame, index: 0)
            encoder.setFragmentTexture(history[0], index: 1)
            encoder.setFragmentTexture(levels[1], index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        history.swapAt(0, 1)
        levels.swapAt(0, 1)
    }

    static let source = """
    /// Mean brightness of the frame (its 1 × 1 mip level) against that of the last picture: the share of the frame
    /// that keeps the change within `step`.
    fragment float4 md_limit_level(QuadOut in [[stage_in]], texture2d<float> frame [[texture(0)]],
                                   texture2d<float> last [[texture(1)]], constant float &step [[buffer(0)]]) {
        float3 c = frame.read(uint2(0), frame.get_num_mip_levels() - 1).rgb;
        float mean = dot(c, float3(0.2126, 0.7152, 0.0722));
        float4 p = last.read(uint2(0));
        if (p.b < 0.5) return float4(mean, 1, 1, 1);
        float change = mean - p.r;
        float k = abs(change) > step ? step / abs(change) : 1;
        return float4(p.r + k * change, k, 1, 1);
    }

    struct LimitOut { float4 screen [[color(0)]]; float4 history [[color(1)]]; };

    /// The frame mixed with the last picture by the share `md_limit_level` found.
    fragment LimitOut md_limit(QuadOut in [[stage_in]], texture2d<float> frame [[texture(0)]],
                               texture2d<float> history [[texture(1)]], texture2d<float> level [[texture(2)]]) {
        uint2 p = uint2(in.position.xy);
        float k = level.read(uint2(0)).g;
        float4 c = mix(history.read(p), frame.read(p, 0), k);
        return { c, c };
    }
    """
}
