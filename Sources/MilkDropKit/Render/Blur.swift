import Metal

/// The three blur levels shaders sample with `GetBlur1…3`, as butterchurn makes them: each level a horizontal and a
/// vertical pass at a smaller size, values stretched to 0…1 between the preset's blur min and max.
final class Blur {
    /// Width and height ratios of the horizontal and the vertical texture of each level.
    private static let ratios: [(Double, Double)] = [(0.5, 0.25), (0.125, 0.125), (0.0625, 0.0625)]
    private let horizontal: MTLRenderPipelineState, vertical: MTLRenderPipelineState
    private var levels: [(h: MTLTexture, v: MTLTexture)] = []

    /// Results of the vertical passes: blur1, blur2, blur3.
    var textures: [MTLTexture] { levels.map(\.v) }
    var horizontalTextures: [MTLTexture] { levels.map(\.h) }

    init?(device: MTLDevice, library: MTLLibrary, size: SIMD2<Int>) {
        guard let h = Self.pipeline(device, library, "md_blur_h"), let v = Self.pipeline(device, library, "md_blur_v") else { return nil }
        horizontal = h
        vertical = v
        resize(device: device, size: size)
    }

    func resize(device: MTLDevice, size: SIMD2<Int>) {
        levels = Self.ratios.compactMap { ratio in
            guard let h = Targets.texture(device, Self.size(size, ratio.0)), let v = Targets.texture(device, Self.size(size, ratio.1)) else { return nil }
            return (h, v)
        }
    }

    /// Blurs `source` into the first `count` levels.
    func encode(_ buffer: MTLCommandBuffer, source: MTLTexture, count: Int, mins: SIMD3<Float>, maxs: SIMD3<Float>, edgeDarken: Float) {
        let (scale, bias) = Self.scaleAndBias(mins: mins, maxs: maxs)
        var input = source
        for level in 0..<min(count, levels.count) {
            var h = HorizontalParams(texsize: Self.texsize(input), scale: scale[level], bias: bias[level])
            pass(buffer, horizontal, from: input, to: levels[level].h, &h)
            let ed = level == 0 ? edgeDarken : 0
            var v = VerticalParams(texsize: Self.texsize(levels[level].h), ed1: 1 - ed, ed2: ed)
            pass(buffer, vertical, from: levels[level].h, to: levels[level].v, &v)
            input = levels[level].v
        }
    }

    private struct HorizontalParams { var texsize: SIMD4<Float>; var scale: Float; var bias: Float }
    private struct VerticalParams { var texsize: SIMD4<Float>; var ed1: Float; var ed2: Float }

    private func pass<P>(_ buffer: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState, from: MTLTexture, to: MTLTexture, _ params: inout P) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = to
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(from, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<P>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Butterchurn's `getScaleAndBias`: each level stretches its range within the range of the level before.
    static func scaleAndBias(mins t: SIMD3<Float>, maxs e: SIMD3<Float>) -> (scale: [Float], bias: [Float]) {
        var r: [Float] = [0, 0, 0], a: [Float] = [0, 0, 0]
        r[0] = 1 / (e[0] - t[0]); a[0] = -t[0] * r[0]
        var i = (t[1] - t[0]) / (e[0] - t[0]), s = (e[1] - t[0]) / (e[0] - t[0])
        r[1] = 1 / (s - i); a[1] = -i * r[1]
        i = (t[2] - t[1]) / (e[1] - t[1]); s = (e[2] - t[1]) / (e[1] - t[1])
        r[2] = 1 / (s - i); a[2] = -i * r[2]
        return (r, a)
    }

    /// Butterchurn's `getBlurValues`: ranges at least 0.1 wide, each level inside the one before.
    static func ranges(_ v: [String: Double]) -> (mins: SIMD3<Float>, maxs: SIMD3<Float>) {
        var e = v["b1n"] ?? 0, i = v["b2n"] ?? 0, s = v["b3n"] ?? 0, r = v["b1x"] ?? 1, a = v["b2x"] ?? 1, h = v["b3x"] ?? 1
        if r - e < 0.1 { let m = 0.5 * (e + r); e = m - 0.05; r = m - 0.05 }
        a = min(r, a); i = max(e, i)
        if a - i < 0.1 { let m = 0.5 * (i + a); i = m - 0.05; a = m - 0.05 }
        h = min(a, h); s = max(i, s)
        if h - s < 0.1 { let m = 0.5 * (s + h); s = m - 0.05; h = m - 0.05 }
        return (SIMD3(Float(e), Float(i), Float(s)), SIMD3(Float(r), Float(a), Float(h)))
    }

    /// Butterchurn's `getTextureSize`: at least 16 px, width a multiple of 16, height of 4.
    private static func size(_ size: SIMD2<Int>, _ ratio: Double) -> SIMD2<Int> {
        let w = max(Double(size.x) * ratio, 16), h = max(Double(size.y) * ratio, 16)
        return SIMD2(16 * Int((w + 3) / 16), 4 * Int((h + 3) / 4))
    }

    private static func texsize(_ t: MTLTexture) -> SIMD4<Float> {
        SIMD4(Float(t.width), Float(t.height), 1 / Float(t.width), 1 / Float(t.height))
    }

    private static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, _ fragment: String) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "md_quad")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = Targets.format
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    /// MSL of the passes; `md_quad` is in `FixedShaders`.
    static let source = """
    struct BlurH { float4 texsize; float scale; float bias; };
    struct BlurV { float4 texsize; float ed1; float ed2; };

    fragment float4 md_blur_h(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant BlurH& p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        const float w[8] = {4, 3.8, 3.5, 2.9, 1.9, 1.2, 0.7, 0.3};
        float4 ws = float4(w[0] + w[1], w[2] + w[3], w[4] + w[5], w[6] + w[7]);
        float4 ds = float4(0 + 2 * w[1] / ws.x, 2 + 2 * w[3] / ws.y, 4 + 2 * w[5] / ws.z, 6 + 2 * w[7] / ws.w);
        float3 blur = float3(0);
        for (int i = 0; i < 4; i++) {
            float2 d = float2(ds[i] * p.texsize.z, 0);
            blur += (t.sample(s, in.uv + d).xyz + t.sample(s, in.uv - d).xyz) * ws[i];
        }
        blur *= 0.5 / (ws.x + ws.y + ws.z + ws.w);
        return float4(blur * p.scale + p.bias, 1);
    }

    fragment float4 md_blur_v(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant BlurV& p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        const float w[8] = {4, 3.8, 3.5, 2.9, 1.9, 1.2, 0.7, 0.3};
        float w1 = w[0] + w[1] + w[2] + w[3], w2 = w[4] + w[5] + w[6] + w[7];
        float d1 = 0 + (w[2] + w[3]) / w1 * 2, d2 = 2 + (w[6] + w[7]) / w2 * 2;
        float3 blur = (t.sample(s, in.uv + float2(0, d1 * p.texsize.w)).xyz + t.sample(s, in.uv - float2(0, d1 * p.texsize.w)).xyz) * w1
                    + (t.sample(s, in.uv + float2(0, d2 * p.texsize.w)).xyz + t.sample(s, in.uv - float2(0, d2 * p.texsize.w)).xyz) * w2;
        blur *= 1 / (2 * (w1 + w2));
        float e = sqrt(min(min(in.uv.x, in.uv.y), 1 - max(in.uv.x, in.uv.y)));
        blur *= p.ed1 + p.ed2 * clamp(e * 5, 0.0, 1.0);
        return float4(blur, 1);
    }
    """
}
