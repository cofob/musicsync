import Metal
import simd

/// Draws MilkDrop frames as butterchurn's `render()`: equations, warp of the last frame, blur, shapes and waves,
/// title, then the comp pass to the screen. While two presets blend, both run and mix.
public final class Renderer {
    public static let meshSize = SIMD2(48, 36)
    static let compSize = SIMD2(32, 24)

    public let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let blur: Blur
    private let noise: Noise.Textures
    private let textures: TextureLibrary
    private let title: TitleText
    private let copy: MTLRenderPipelineState
    /// Triangles of the warp mesh and of the comp grid, made once.
    private let warpIndices: MTLBuffer, compIndices: MTLBuffer
    private let geometry: FrameGeometry
    private let arenas: FrameArenas
    private let wrapSampler: MTLSamplerState, clampSampler: MTLSamplerState
    private var targets: Targets?
    private var mesh = WarpMesh(size: meshSize)
    private let audio = AudioLevels()
    let globals = EELGlobals()
    /// Every random value comes from here, so tests can make frames repeatable.
    private let random: () -> Double

    /// A preset on screen: compiled shaders, its equations and its random values.
    final class Active {
        let compiled: CompiledPreset
        let equations: PresetEquations
        let geometry: PresetGeometry
        let randPreset: SIMD4<Float>, randStart: SIMD4<Float>
        init(_ compiled: CompiledPreset, _ equations: PresetEquations, _ geometry: PresetGeometry, random: () -> Double) {
            self.compiled = compiled
            self.equations = equations
            self.geometry = geometry
            randStart = SIMD4((0..<4).map { _ in Float(random()) })
            randPreset = SIMD4((0..<4).map { _ in Float(random()) })
        }
    }

    private(set) var current: Active?
    private var previous: Active?
    private var pattern: BlendPattern
    private var blendStart = 0.0, blendDuration = 0.0
    private(set) var time = 0.0, fps = 30.0, frame = 0
    private var lastNow: Double?
    private var timeHistory = [0.0]

    public init?(device: MTLDevice, textureFolders: [URL] = [], random: @escaping () -> Double = { .random(in: 0..<1) }) {
        guard let queue = device.makeCommandQueue(),
              let library = try? FixedShaders.library(device: device, extra: []),
              let blur = Blur(device: device, library: library, size: SIMD2(16, 16)),
              let noise = Noise.makeTextures(device: device, queue: queue, random: random),
              let title = TitleText(device: device, library: library),
              let copy = Self.copyPipeline(device, library),
              let geometry = FrameGeometry(device: device, library: library),
              let wrap = Self.sampler(device, .repeat), let clamp = Self.sampler(device, .clampToEdge) else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        self.blur = blur
        self.noise = noise
        self.title = title
        self.copy = copy
        arenas = FrameArenas(device: device)
        guard let wi = Self.indexBuffer(device, Self.meshSize), let ci = Self.indexBuffer(device, Self.compSize) else { return nil }
        warpIndices = wi
        compIndices = ci
        self.geometry = geometry
        wrapSampler = wrap
        clampSampler = clamp
        self.random = random
        textures = TextureLibrary(device: device, folders: [MilkDropResources.textures].compactMap { $0 } + textureFolders, random: random)
        pattern = BlendPattern(width: Self.meshSize.x, height: Self.meshSize.y, aspect: SIMD2(1, 1), random: random)
    }

    /// Shows `compiled`, mixing it in over `blend` seconds. Throws when its equations do not compile.
    public func show(_ compiled: CompiledPreset, blend: Double) throws {
        var preset = compiled.preset
        preset.values["old_wave_mode"] = current?.compiled.preset.values["wave_mode"] ?? preset.values["wave_mode"]
        let equations = try PresetEquations(preset, globals: globals, frame: frameGlobals, random: random)
        let shapes = try PresetGeometry(preset, globals: globals, frame: frameGlobals, random: random)
        // Images of the old preset stay while it blends out; random picks are new for the new preset.
        textures.keep(Set((current.map { [$0.compiled.warp, $0.compiled.comp] } ?? []).flatMap { $0.userTextures.map(\.name) }))
        previous = blend > 0 ? current : nil
        current = Active(compiled, equations, shapes, random: random)
        blendStart = time
        blendDuration = blend
        pattern = BlendPattern(width: Self.meshSize.x, height: Self.meshSize.y, aspect: SIMD2(Float(aspect.x), Float(aspect.y)), random: random)
    }

    /// MilkDrop's song title animation, shown for `seconds`.
    public func showTitle(_ text: String, seconds: Double) {
        title.show(text, time: time, duration: seconds, size: targets?.size ?? SIMD2(512, 512))
    }

    /// Renders one frame into `screen`. `size`: pixels of the frame textures (the screen size times the quality).
    /// `left`/`right`: the samples that play now, `now`: seconds of a steady clock.
    public func render(into screen: MTLTexture, buffer: MTLCommandBuffer, size: SIMD2<Int>,
                       left: [Float], right: [Float], sampleRate: Double, now: Double) {
        resize(size, buffer)
        guard let current, var targets = self.targets else { return }
        arenas.begin(buffer)
        advanceTime(now)
        audio.update(left: left, right: right, sampleRate: sampleRate, fps: fps, frame: frame)
        let g = frameGlobals
        let progress = blendDuration > 0 ? (time - blendStart) / blendDuration : 1
        if progress >= 1 { previous = nil }
        let old = previous
        current.equations.runFrame(g)
        mesh.update(current.equations, time: time, aspect: aspect)
        var mixed = current.equations.values
        if let old {
            old.equations.runFrame(g)
            mesh.update(old.equations, time: time, aspect: aspect, blend: (pattern, Float(progress)))
            mixed = Self.mix(progress, new: mixed, old: old.equations.values)
        }

        targets.swap()
        self.targets = targets
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: targets.prev)
            blit.endEncoding()
        }
        let (mins, maxs) = Blur.ranges(mixed)

        // Warp the last frame into the target.
        if let encoder = pass(buffer, targets.target, clear: true) {
            if let old {
                drawWarp(encoder, old, values: old.equations.values, blend: false, mins: mins, maxs: maxs)
            }
            drawWarp(encoder, current, values: old == nil ? current.equations.values : mixed, blend: old != nil, mins: mins, maxs: maxs)
            encoder.endEncoding()
        }
        if current.compiled.blurLevel > 0 {
            blur.encode(buffer, source: targets.target, count: current.compiled.blurLevel, mins: mins, maxs: maxs,
                        edgeDarken: Float(current.equations.values["b1ed"] ?? 0.25))
        }
        if let encoder = pass(buffer, targets.target, clear: false) {
            geometry.encode(encoder, arena: arenas, prev: targets.prev, current: (current.geometry, current.equations),
                            previous: old.map { ($0.geometry, $0.equations) }, blendProgress: min(progress, 1),
                            mixed: mixed, frame: g, audio: audio, mesh: mesh)
            if let t = title.progress(at: time), t >= 1 {
                title.draw(encoder, progress: t, intoTarget: true, time: time, size: targets.size, invAspectY: Float(1 / aspect.y))
            }
            encoder.endEncoding()
        }

        // Comp to the screen.
        if let encoder = pass(buffer, screen, clear: true) {
            if let old { drawComp(encoder, old, values: old.equations.values, blend: false, mins: mins, maxs: maxs) }
            drawComp(encoder, current, values: mixed, blend: old != nil, mins: mins, maxs: maxs)
            if let t = title.progress(at: time) {
                title.draw(encoder, progress: t, intoTarget: false, time: time, size: targets.size, invAspectY: Float(1 / aspect.y))
                if t >= 1 { title.finish() }
            }
            encoder.endEncoding()
        }
    }

    // MARK: Passes

    private func drawWarp(_ encoder: MTLRenderCommandEncoder, _ active: Active, values: [String: Double], blend: Bool,
                          mins: SIMD3<Float>, maxs: SIMD3<Float>) {
        guard let targets else { return }
        var vertices = mesh.vertices(alpha: blend)
        encoder.setRenderPipelineState(active.compiled.warpPipeline)
        bind(encoder, vertices: &vertices, indices: warpIndices, active, shader: active.compiled.warp, values: values, main: targets.prev, mins: mins, maxs: maxs)
    }

    private func drawComp(_ encoder: MTLRenderCommandEncoder, _ active: Active, values: [String: Double], blend: Bool,
                          mins: SIMD3<Float>, maxs: SIMD3<Float>) {
        guard let targets else { return }
        var vertices = compVertices(active, blend: blend)
        encoder.setRenderPipelineState(active.compiled.compPipeline)
        bind(encoder, vertices: &vertices, indices: compIndices, active, shader: active.compiled.comp, values: values, main: targets.target, mins: mins, maxs: maxs)
    }

    /// Sets vertices, uniforms, textures and the `sampler_main` sampler, then draws the triangles.
    private func bind(_ encoder: MTLRenderCommandEncoder, vertices: inout [Float], indices: MTLBuffer, _ active: Active, shader: TranslatedShader,
                      values: [String: Double], main: MTLTexture, mins: SIMD3<Float>, maxs: SIMD3<Float>) {
        let user = shader.userTextures.map { textures.texture($0.name) }
        var uniforms = ShaderUniforms(shaderFrame(values, active, mins: mins, maxs: maxs, user: user))
        guard let (buffer, offset) = vertices.withUnsafeBytes({ arenas.append($0) }) else { return }
        encoder.setVertexBuffer(buffer, offset: offset, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 1)
        let fixed: [MTLTexture?] = [main] + blur.textures + [noise.lq, noise.mq, noise.hq, noise.volumeLQ, noise.volumeHQ]
        for (i, t) in (fixed + user).enumerated() { encoder.setFragmentTexture(t ?? noise.lq, index: i) }
        encoder.setFragmentSamplerState((values["wrap"] ?? 1) != 0 ? wrapSampler : clampSampler, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indices.length / 4, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
    }

    private func shaderFrame(_ v: [String: Double], _ active: Active, mins: SIMD3<Float>, maxs: SIMD3<Float>, user: [MTLTexture?]) -> ShaderFrame {
        var f = ShaderFrame()
        let size = targets?.size ?? SIMD2(1, 1)
        f.size = SIMD2(Float(size.x), Float(size.y))
        f.aspect = SIMD2(Float(aspect.x), Float(aspect.y))
        (f.time, f.fps, f.frame) = (Float(time), Float(fps), Float(frame))
        (f.bass, f.mid, f.treb) = (audio.bass, audio.mid, audio.treb)
        (f.bassAtt, f.midAtt, f.trebAtt) = (audio.bassAtt, audio.midAtt, audio.trebAtt)
        f.vol = (f.bass + f.mid + f.treb) / 3
        f.volAtt = (f.bassAtt + f.midAtt + f.trebAtt) / 3
        f.q = active.equations.q.map(Float.init)
        f.randPreset = active.randPreset
        f.randFrame = SIMD4((0..<4).map { _ in Float(random()) })
        let n = { (key: String, fallback: Double) in Float(v[key] ?? fallback) }
        (f.decay, f.gammaAdj, f.echoZoom) = (n("decay", 0.98), n("gammaadj", 2), n("echo_zoom", 2))
        (f.echoAlpha, f.echoOrient, f.fShader) = (n("echo_alpha", 0), n("echo_orient", 0), n("fshader", 0))
        (f.invert, f.brighten) = (n("invert", 0) != 0, n("brighten", 0) != 0)
        (f.darken, f.solarize) = (n("darken", 0) != 0, n("solarize", 0) != 0)
        (f.blurMin, f.blurMax) = (mins, maxs)
        f.userTextureSizes = user.map { SIMD2(Float($0?.width ?? 1), Float($0?.height ?? 1)) }
        return f
    }

    /// The comp grid as `MDVertex`, one per grid vertex (drawn with `compIndices`): uv with 0 at the top, as
    /// butterchurn's comp shader flips it, color = hue shade of the four corners, alpha = the new preset's blend share.
    private func compVertices(_ active: Active, blend: Bool) -> [Float] {
        let hue = hueBase(active.randStart)
        let (w, h) = (Self.compSize.x, Self.compSize.y), n = WarpMesh.floatsPerVertex
        return [Float](unsafeUninitializedCapacity: (w + 1) * (h + 1) * n) { out, count in
            var o = 0
            for row in 0...h {
                for col in 0...w {
                    let u = Float(col) / Float(w), v = Float(row) / Float(h)
                    let c = { (k: Int) in hue[k] * u * v + hue[3 + k] * (1 - u) * v + hue[6 + k] * u * (1 - v) + hue[9 + k] * (1 - u) * (1 - v) }
                    let du = u - 0.5, dv = v - 0.5
                    (out[o], out[o + 1], out[o + 2], out[o + 3]) = (u * 2 - 1, 1 - v * 2, u, v)  // row 0 at the top of the screen
                    (out[o + 4], out[o + 5], out[o + 6], out[o + 7]) = (u, v, (du * du + dv * dv).squareRoot(), atan2(du, dv))
                    (out[o + 8], out[o + 9], out[o + 10], out[o + 11]) = (c(0), c(1), c(2), blend ? meshAlpha(u, v) : 1)
                    o += n
                }
            }
            count = o
        }
    }

    /// The warp mesh alpha at (u, v) of the comp grid, as butterchurn's `generateCompColors`.
    private func meshAlpha(_ u: Float, _ v: Float) -> Float {
        let mw = Self.meshSize.x, mh = Self.meshSize.y
        let x = min(max(u * Float(mw + 1), 0), Float(mw - 1)), y = min(max(v * Float(mh + 1), 0), Float(mh - 1))
        let ix = Int(x), iy = Int(y), fx = x - Float(ix), fy = y - Float(iy)
        let a = { (c: Int, r: Int) in self.mesh.alphas[r * (mw + 1) + c] }
        return a(ix, iy) * (1 - fx) * (1 - fy) + a(ix + 1, iy) * fx * (1 - fy) + a(ix, iy + 1) * (1 - fx) * fy + a(ix + 1, iy + 1) * fx * fy
    }

    /// Butterchurn's `generateHueBase`: four slowly changing corner colors.
    private func hueBase(_ randStart: SIMD4<Float>) -> [Float] {
        var e = [Float](repeating: 1, count: 12)
        let t = time
        for i in 0..<4 {
            let fi = Double(i)
            e[3 * i] = Float(0.6 + 0.3 * sin(30 * t * 0.0143 + 3 + 21 * fi + Double(randStart[3])))
            e[3 * i + 1] = Float(0.6 + 0.3 * sin(30 * t * 0.0107 + 1 + 13 * fi + Double(randStart[1])))
            e[3 * i + 2] = Float(0.6 + 0.3 * sin(30 * t * 0.0129 + 6 + 9 * fi + Double(randStart[2])))
            let m = max(e[3 * i], e[3 * i + 1], e[3 * i + 2])
            for r in 0..<3 { e[3 * i + r] = 0.5 + 0.5 * e[3 * i + r] / m }
        }
        return e
    }

    // MARK: Frame state

    /// Butterchurn's `aspectx`/`aspecty`: the shorter side over the longer one, 1 for the longer side.
    var aspect: SIMD2<Double> {
        let s = targets?.size ?? SIMD2(1, 1), w = Double(s.x), h = Double(s.y)
        return SIMD2(h > w ? w / h : 1, w > h ? h / w : 1)
    }

    var frameGlobals: FrameGlobals {
        FrameGlobals(time: time, fps: fps, frame: Double(frame),
                     bass: Double(audio.bass), mid: Double(audio.mid), treb: Double(audio.treb),
                     bassAtt: Double(audio.bassAtt), midAtt: Double(audio.midAtt), trebAtt: Double(audio.trebAtt),
                     meshSize: Self.meshSize, aspect: aspect, pixels: targets?.size ?? SIMD2(1, 1))
    }

    /// Butterchurn's `calcTimeAndFPS`: time moves by 1/fps, fps follows the frame times of the last 120 frames.
    private func advanceTime(_ now: Double) {
        var dt = lastNow.map { now - $0 } ?? 1.0 / 60
        if dt > 1 || dt < 0 { dt = 1.0 / 30 }
        lastNow = now
        time += 1 / fps
        let sum = (timeHistory.last ?? 0) + dt
        timeHistory.append(sum)
        if timeHistory.count > 120 { timeHistory.removeFirst() }
        fps = 0.93 * fps + 0.07 * Double(timeHistory.count) / (sum - timeHistory[0])
        frame += 1
    }

    /// Butterchurn's `mixFrameEquations`: numbers ease across, switches flip halfway.
    static func mix(_ t: Double, new e: [String: Double], old i: [String: Double]) -> [String: Double] {
        let s = 0.5 - 0.5 * cos(t * .pi), r = 1 - s
        var a = e
        for key in ["decay", "wave_a", "wave_r", "wave_g", "wave_b", "wave_x", "wave_y", "wave_mystery", "ob_size", "ob_r", "ob_g",
                    "ob_b", "ob_a", "ib_size", "ib_r", "ib_g", "ib_b", "ib_a", "mv_x", "mv_y", "mv_dx", "mv_dy", "mv_l", "mv_r", "mv_g",
                    "mv_b", "mv_a", "echo_zoom", "echo_alpha", "echo_orient", "b1n", "b2n", "b3n", "b1x", "b2x", "b3x", "b1ed"] {
            a[key] = s * (e[key] ?? 0) + r * (i[key] ?? 0)
        }
        for key in ["wave_dots", "wave_thick", "additivewave", "wave_brighten", "darken_center", "gammaadj", "wrap", "invert",
                    "brighten", "darken", "solarize"] {
            a[key] = s < 0.5 ? i[key] : e[key]
        }
        return a
    }

    // MARK: Metal helpers

    private func pass(_ buffer: MTLCommandBuffer, _ texture: MTLTexture, clear: Bool) -> MTLRenderCommandEncoder? {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = texture
        d.colorAttachments[0].loadAction = clear ? .clear : .load
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: clear && texture.pixelFormat != Targets.format ? 1 : 0)
        d.colorAttachments[0].storeAction = .store
        return buffer.makeRenderCommandEncoder(descriptor: d)
    }

    /// New frame textures for a new size, with the picture scaled over, as butterchurn's resample shader.
    private func resize(_ size: SIMD2<Int>, _ buffer: MTLCommandBuffer) {
        let size = SIMD2(max(size.x, 16), max(size.y, 16))
        guard targets?.size != size, let fresh = Targets(device: device, size: size) else { return }
        let old = targets
        targets = fresh
        blur.resize(device: device, size: size)
        // New textures hold garbage; butterchurn's start black.
        for texture in [fresh.prev, fresh.target] + blur.textures + blur.horizontalTextures {
            pass(buffer, texture, clear: true)?.endEncoding()
        }
        // Their smaller mip levels too: the comp pass reads the target's mips before any frame made them.
        if let blit = buffer.makeBlitCommandEncoder() {
            [fresh.prev, fresh.target].forEach(blit.generateMipmaps)
            blit.endEncoding()
        }
        if let old, let encoder = pass(buffer, fresh.target, clear: true) {
            encoder.setRenderPipelineState(copy)
            encoder.setFragmentTexture(old.target, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
    }

    private static func indexBuffer(_ device: MTLDevice, _ size: SIMD2<Int>) -> MTLBuffer? {
        let indices = WarpMesh.indices(size)
        return device.makeBuffer(bytes: indices, length: indices.count * 4)
    }

    private static func copyPipeline(_ device: MTLDevice, _ library: MTLLibrary) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "md_quad")
        d.fragmentFunction = library.makeFunction(name: "md_copy")
        d.colorAttachments[0].pixelFormat = Targets.format
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    private static func sampler(_ device: MTLDevice, _ mode: MTLSamplerAddressMode) -> MTLSamplerState? {
        let d = MTLSamplerDescriptor()
        (d.minFilter, d.magFilter, d.mipFilter) = (.linear, .linear, .linear)
        (d.sAddressMode, d.tAddressMode) = (mode, mode)
        return device.makeSamplerState(descriptor: d)
    }
}
