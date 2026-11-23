import CoreGraphics
import CoreText
import Metal

/// MilkDrop's song title animation as butterchurn draws it: italic white text that flies in on a waving mesh over the
/// picture, then is drawn once into the frame texture, where the warp melts it away.
final class TitleText {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let positions: [SIMD2<Float>]
    private let indices: MTLBuffer
    private var texture: MTLTexture?
    private(set) var start: Double?
    private(set) var duration = 1.7

    init?(device: MTLDevice, library: MTLLibrary) {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "md_title_vertex")
        d.fragmentFunction = library.makeFunction(name: "md_title_fragment")
        d.colorAttachments[0].pixelFormat = Targets.format
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let state = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        var index: [UInt16] = []
        for row in 0..<7 {
            for col in 0..<15 {
                let a = UInt16(col + 16 * row), b = UInt16(col + 16 * (row + 1))
                index += [a, b, a + 1, b, b + 1, a + 1]
            }
        }
        guard let buffer = device.makeBuffer(bytes: index, length: index.count * 2) else { return nil }
        self.device = device
        pipeline = state
        indices = buffer
        var grid: [SIMD2<Float>] = []
        for row in 0..<8 {
            for col in 0..<16 { grid.append(SIMD2<Float>(Float(col) * 2 / 15 - 1, 1 - Float(row) * 2 / 7)) }
        }
        positions = grid
    }

    /// Starts the animation of `text` at `time`, drawn for a target of `size` pixels.
    func show(_ text: String, time: Double, duration: Double, size: SIMD2<Int>) {
        texture = Self.render(text, size: size, device: device)
        start = time
        self.duration = duration
    }

    /// Progress at `time`, 0 at the start; nil when no title shows.
    func progress(at time: Double) -> Double? { start.map { (time - $0) / duration } }

    func finish() { start = nil }

    /// Draws the title. `intoTarget`: the offscreen frame texture (once, at the end); else the screen.
    func draw(_ encoder: MTLRenderCommandEncoder, progress t: Double, intoTarget: Bool, time: Double, size: SIMD2<Int>, invAspectY: Float) {
        guard let texture else { return }
        var uvs = [SIMD2<Float>]()
        uvs.reserveCapacity(128)
        for row in 0..<8 {
            for col in 0..<16 {
                var o = 2 * (0.75 * (Double(row) / 7 - 0.5) + 0.5) - 1
                if t >= 1 { o += 1 / Double(size.y) }
                uvs.append(SIMD2(Float(2 * (Double(col) / 15) - 1), Float(intoTarget ? o : -o)))
            }
        }
        let n = max(0, 1 - 1.5 * t), l = 1.3 * pow(n, 1.8)
        for i in uvs.indices {
            var x = Double(uvs[i].x), y = Double(uvs[i].y)
            x += 0.07 * l * sin(0.31 * time + 0.39 * x - 1.94 * y)
            x += 0.044 * l * sin(0.81 * time - 1.91 * x + 0.27 * y)
            x += 0.061 * l * sin(1.31 * time + 0.61 * x + 0.74 * y)
            y += 0.061 * l * sin(0.37 * time + 1.83 * x + 0.69 * y)
            y += 0.07 * l * sin(0.67 * time + 0.42 * x - 1.39 * y)
            y += 0.087 * l * sin(1.07 * time + 3.55 * x + 0.89 * y)
            let c = 1.01 / (pow(max(t, 0), 0.21) + 0.01)
            uvs[i] = SIMD2(Float((x * c + 1) / 2), Float((y * c * Double(invAspectY) + 1) / 2))
        }
        var vertices = zip(positions, uvs).map { SIMD4($0.x, intoTarget ? -$0.y : $0.y, $1.x, $1.y) }
        var color = Float(pow(max(t, 0), 0.3))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&color, length: 4, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indices.length / 2, indexType: .uint16, indexBuffer: indices, indexBufferOffset: 0)
    }

    /// White italic Times New Roman, centered, as butterchurn's canvas draws it; rows bottom first (GL order).
    private static func render(_ text: String, size: SIMD2<Int>, device: MTLDevice) -> MTLTexture? {
        let (w, h) = (max(size.x, 1), max(size.y, 1))
        let fontSize = CGFloat(max(w * 16 / 256, 6))
        let font = CTFontCreateWithName("TimesNewRomanPS-ItalicMT" as CFString, fontSize, nil)
        func line(_ s: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
        }
        var shown = line(text), width = CTLineGetTypographicBounds(shown, nil, nil, nil)
        if width > Double(w) {
            let keep = Int(Double(text.count) * Double(w) / width * 0.91)
            shown = line(String(text.prefix(keep)) + "...")
            width = CTLineGetTypographicBounds(shown, nil, nil, nil)
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            // Canvas puts the baseline at h/2 from the top; CoreGraphics counts from the bottom.
            context.textPosition = CGPoint(x: (Double(w) - width) / 2, y: Double(h) / 2)
            CTLineDraw(shown, context)
        }
        // Not premultiplied, as canvas data: the text is white wherever it has alpha.
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 0 { (bytes[i], bytes[i + 1], bytes[i + 2]) = (255, 255, 255) }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        // CoreGraphics memory is top row first; GL order is bottom first, as butterchurn's UNPACK_FLIP_Y gives.
        for row in 0..<h {
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, h - 1 - row, w, 1), mipmapLevel: 0, withBytes: $0.baseAddress! + row * w * 4, bytesPerRow: w * 4)
            }
        }
        return texture
    }

    static let source = """
    struct TitleOut { float4 position [[position]]; float2 uv; };

    vertex TitleOut md_title_vertex(uint id [[vertex_id]], const device float4* v [[buffer(0)]]) {
        TitleOut out;
        out.position = float4(v[id].xy, 0, 1);
        out.uv = v[id].zw;
        return out;
    }

    fragment float4 md_title_fragment(TitleOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float& color [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return t.sample(s, in.uv) * color;
    }
    """
}
