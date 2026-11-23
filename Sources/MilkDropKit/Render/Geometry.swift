import Metal

/// One vertex of the geometry passes: position in GL clip space (y up), uv for textured shapes, color.
struct GeometryVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float> = .zero
    var color: SIMD4<Float>
}

/// The vertices and draws of the geometry passes of one frame, in drawing order. Filled on the CPU, then encoded
/// with one vertex buffer.
final class GeometryBatch {
    /// How a draw samples the previous frame: not at all, or as a textured shape with the preset's `wrap`.
    enum Sampling { case none, clamp, wrap }

    struct Draw {
        var primitive: MTLPrimitiveType
        var start: Int, count: Int
        var additive: Bool
        var sampling: Sampling
        /// Added to every position, in GL clip units (butterchurn's `thickOffset`).
        var offset: SIMD2<Float>
        var pointSize: Float
    }

    private(set) var vertices: [GeometryVertex] = []
    private(set) var draws: [Draw] = []

    func reset() {
        vertices.removeAll(keepingCapacity: true)
        draws.removeAll(keepingCapacity: true)
    }

    func append(_ vertex: GeometryVertex) { vertices.append(vertex) }

    /// Draws the vertices from `start` to the end. `thick`: four passes shifted by 0, (x, 0), (0, y) and (x, y),
    /// as butterchurn draws thick lines and dots.
    func draw(_ primitive: MTLPrimitiveType, from start: Int, additive: Bool, sampling: Sampling = .none,
              thick: SIMD2<Float>? = nil, pointSize: Float = 1) {
        let count = vertices.count - start
        guard count > 0 else { return }
        func add(_ offset: SIMD2<Float>) {
            draws.append(Draw(primitive: primitive, start: start, count: count, additive: additive, sampling: sampling,
                              offset: offset, pointSize: pointSize))
        }
        add(.zero)
        if let t = thick {
            add(SIMD2(t.x, 0)); add(SIMD2(0, t.y)); add(t)
        }
    }
}

/// Pipelines of the geometry passes: alpha or additive blending, plain or textured.
final class GeometryPipelines {
    private let device: MTLDevice
    /// Index: additive + 2 × textured.
    private let states: [MTLRenderPipelineState]
    private let clamp: MTLSamplerState, wrap: MTLSamplerState

    init?(device: MTLDevice, library: MTLLibrary) {
        var states: [MTLRenderPipelineState] = []
        for textured in [false, true] {
            for additive in [false, true] {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: "md_geo_vertex")
                d.fragmentFunction = library.makeFunction(name: textured ? "md_geo_textured" : "md_geo_color")
                let c = d.colorAttachments[0]!
                c.pixelFormat = Targets.format
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.sourceAlphaBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
                guard let state = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
                states.append(state)
            }
        }
        func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState? {
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            d.mipFilter = .linear
            d.sAddressMode = mode
            d.tAddressMode = mode
            return device.makeSamplerState(descriptor: d)
        }
        guard let clamp = sampler(.clampToEdge), let wrap = sampler(.repeat) else { return nil }
        self.device = device
        self.states = states
        self.clamp = clamp
        self.wrap = wrap
    }

    private struct Params { var offset: SIMD2<Float>; var pointSize: Float }

    /// Encodes the batch into an encoder whose attachment is the frame target; textured shapes sample `prev`.
    func encode(_ batch: GeometryBatch, into encoder: MTLRenderCommandEncoder, arena: FrameArenas, prev: MTLTexture) {
        let vertices = batch.vertices
        guard !batch.draws.isEmpty, let (buffer, offset) = vertices.withUnsafeBytes({ arena.append($0) }) else { return }
        encoder.setVertexBuffer(buffer, offset: offset, index: 0)
        var current = -1
        for d in batch.draws {
            let index = (d.additive ? 1 : 0) + (d.sampling == .none ? 0 : 2)
            if index != current {
                encoder.setRenderPipelineState(states[index])
                current = index
            }
            if d.sampling != .none {
                encoder.setFragmentTexture(prev, index: 0)
                encoder.setFragmentSamplerState(d.sampling == .wrap ? wrap : clamp, index: 0)
            }
            var params = Params(offset: d.offset, pointSize: d.pointSize)
            encoder.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
            encoder.drawPrimitives(type: d.primitive, vertexStart: d.start, vertexCount: d.count)
        }
    }

    /// MSL of the passes. Positions come in GL clip space; y is flipped for the GL-row-order target. Colors are
    /// clamped as GL does for an 8-bit target before it blends.
    static let source = """
    struct GeoVertex { float2 position; float2 uv; float4 color; };
    struct GeoParams { float2 offset; float pointSize; };
    struct GeoOut { float4 position [[position]]; float4 color; float2 uv; float size [[point_size]]; };
    struct GeoIn { float4 position [[position]]; float4 color; float2 uv; };

    vertex GeoOut md_geo_vertex(uint id [[vertex_id]], const device GeoVertex* v [[buffer(0)]], constant GeoParams& p [[buffer(1)]]) {
        float2 q = v[id].position + p.offset;
        GeoOut out;
        out.position = float4(q.x, -q.y, 0, 1);
        out.color = v[id].color;
        out.uv = v[id].uv;
        out.size = p.pointSize;
        return out;
    }

    fragment float4 md_geo_color(GeoIn in [[stage_in]]) { return saturate(in.color); }

    fragment float4 md_geo_textured(GeoIn in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return saturate(t.sample(s, in.uv) * in.color);
    }
    """
}

/// Variables of one custom shape or wave, with butterchurn's lifetimes: the file values come back every frame,
/// q1…q32 come from the main preset's per-frame code, t1…t8 come back to their values after init, and the element's
/// own variables carry over. Init sees q and t as 0: butterchurn's converter sets every used variable to 0 first.
/// Each element has its own megabuf, as in butterchurn.
final class ElementEquations {
    let scope: EELScope
    private let base: [(slot: Int, value: Double)]
    private let qSlots: [Int], tSlots: [Int], globalSlots: [Int]
    private var tInit: [Double] = []

    init(values: [String: Double], initCode: String, globals: EELGlobals, frame: FrameGlobals,
         random: @escaping () -> Double = { .random(in: 0..<1) }) throws {
        let scope = EELScope(memory: EELMemory(), globals: globals, random: random)
        self.scope = scope
        base = values.map { (scope.slot($0.key), $0.value) }
        qSlots = PresetEquations.qNames.map(scope.slot)
        tSlots = (1...8).map { scope.slot("t\($0)") }
        globalSlots = frame.named.map { scope.slot($0.0) }
        let program = try scope.compile(initCode)
        setBase(frame)
        scope.run(program)
        for (slot, value) in base { scope[slot] = value }
        tInit = tSlots.map { scope[$0] }
    }

    /// Sets the variables a frame starts with; `q`: the main preset's after its per-frame code.
    func beginFrame(q: [Double], frame: FrameGlobals) {
        setBase(frame)
        for (slot, value) in zip(qSlots, q) { scope[slot] = value }
        for (slot, value) in zip(tSlots, tInit) { scope[slot] = value }
    }

    private func setBase(_ frame: FrameGlobals) {
        for (slot, value) in base { scope[slot] = value }
        for (slot, value) in zip(globalSlots, frame.named) { scope[slot] = value.1 }
    }
}

/// The custom shapes and waves of one preset.
final class PresetGeometry {
    let shapes: [CustomShape]
    let waves: [CustomWave]

    init(_ preset: Preset, globals: EELGlobals, frame: FrameGlobals, random: @escaping () -> Double = { .random(in: 0..<1) }) throws {
        shapes = try preset.shapes.filter(\.isEnabled).map { try CustomShape($0, globals: globals, frame: frame, random: random) }
        waves = try preset.waves.filter(\.isEnabled).map { try CustomWave($0, globals: globals, frame: frame, random: random) }
    }

    /// Adds this frame's shapes, then waves. `eq`: this preset's equations after per-frame code.
    /// `alpha`: the preset's share, 1 when not blending.
    func add(to batch: GeometryBatch, eq: PresetEquations, frame: FrameGlobals, audio: AudioLevels, alpha: Double) {
        let wrap = (eq.values["wrap"] ?? 1) != 0
        for shape in shapes { shape.add(to: batch, q: eq.q, wrap: wrap, frame: frame, alpha: alpha) }
        let waveScale = eq.preset.values["wave_scale"] ?? 1
        for wave in waves { wave.add(to: batch, q: eq.q, waveScale: waveScale, frame: frame, audio: audio, alpha: alpha) }
    }
}

/// Everything drawn on the frame texture after the warp pass, in butterchurn's order: motion vectors, the new
/// preset's shapes and waves, the old preset's, the basic wave, darken center, outer and inner border.
final class FrameGeometry {
    typealias Part = (geometry: PresetGeometry, equations: PresetEquations)
    let pipelines: GeometryPipelines
    let batch = GeometryBatch()
    private let basicWave = BasicWave()

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let pipelines = GeometryPipelines(device: device, library: library) else { return nil }
        self.pipelines = pipelines
    }

    /// `current`: the new preset; `previous`: the old one while blending, with `blendProgress` (0…1) the new one's
    /// linear share. `mixed`: butterchurn's `mixFrameEquations` of the two (or `current.equations.values`).
    /// `mesh`: this frame's warp mesh (blended uvs). `encoder` draws into the frame target; `prev` is the frame
    /// warped from (textured shapes sample it, with mipmaps).
    func encode(_ encoder: MTLRenderCommandEncoder, arena: FrameArenas, prev: MTLTexture, current: Part, previous: Part?, blendProgress: Double,
                mixed: [String: Double], frame: FrameGlobals, audio: AudioLevels, mesh: WarpMesh) {
        batch.reset()
        MotionVectors.add(to: batch, values: mixed, mesh: mesh, frame: frame)
        current.geometry.add(to: batch, eq: current.equations, frame: frame, audio: audio, alpha: previous == nil ? 1 : blendProgress)
        if let previous {
            previous.geometry.add(to: batch, eq: previous.equations, frame: frame, audio: audio, alpha: 1 - blendProgress)
        }
        basicWave.add(to: batch, values: mixed, blendProgress: previous == nil ? nil : blendProgress, frame: frame, audio: audio)
        Borders.add(to: batch, values: mixed, frame: frame)
        pipelines.encode(batch, into: encoder, arena: arena, prev: prev)
    }
}

extension Double {
    /// `floor` as an Int, or nil when not finite (where butterchurn's math gets NaN and draws nothing).
    var floorInt: Int? { isFinite ? Int(Swift.min(Swift.max(rounded(.down), -1e9), 1e9)) : nil }

    /// Butterchurn's `Math.clamp`.
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}
