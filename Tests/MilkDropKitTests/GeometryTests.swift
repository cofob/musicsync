import Foundation
import Metal
@testable import MilkDropKit
import Testing

@Suite struct GeometryTests {
    private let frame = FrameGlobals(time: 1, frame: 2, aspect: SIMD2(0.625, 1), pixels: SIMD2(320, 200))

    private func setup(_ text: String) throws -> (PresetEquations, PresetGeometry) {
        let preset = PresetFile.parse("[preset00]\n" + text, name: "T")
        let globals = EELGlobals()
        let eq = try PresetEquations(preset, globals: globals, frame: frame)
        return (eq, try PresetGeometry(preset, globals: globals, frame: frame))
    }

    private func audio() -> AudioLevels {
        let audio = AudioLevels()
        let samples = (0..<1024).map { Float(sin(Double($0) * 0.05) * 0.5) }
        audio.update(left: samples, right: samples.map { -$0 }, sampleRate: 44100, fps: 60, frame: 1)
        return audio
    }

    @Test func shapeLifetimes() throws {
        let (eq, geometry) = try setup("""
        per_frame_1=q2 = 3;
        shapecode_0_enabled=1
        shapecode_0_sides=4
        shapecode_0_num_inst=3
        shapecode_0_x=0.5
        shape_0_init1=t1 = 2; mine = 10;
        shape_0_per_frame1=x = x + instance * 0.1; t1 = t1 + 1; mine = mine + 1; seen = q2;
        """)
        let shape = try #require(geometry.shapes.first)
        let batch = GeometryBatch()
        for round in 1...2 {
            batch.reset()
            shape.add(to: batch, q: eq.q, wrap: true, frame: frame, alpha: 1)
            #expect(shape.eq.scope["t1"] == 5)  // back to 2 each frame, + 1 per instance
            #expect(shape.eq.scope["mine"] == Double(10 + 3 * round))
            #expect(shape.eq.scope["seen"] == 3)
            #expect(abs(shape.eq.scope["x"] - 0.7) < 1e-9)  // file value again each instance
        }
        // Instance n is centered at 2 × (0.5 + 0.1 n) − 1; fans of 4 triangles, 12 vertices.
        let fans = batch.draws.filter { $0.primitive == .triangle }
        let centers = fans.map { batch.vertices[$0.start].position.x }
        #expect(centers.count == 3)
        for (n, x) in centers.enumerated() { #expect(abs(x - 0.2 * Float(n)) < 1e-5) }
        #expect(fans.allSatisfy { $0.count == 12 })
        #expect(batch.draws.count == 6)  // and a border line each (border_a 0.1)
    }

    @Test func waveLifetimes() throws {
        let (eq, geometry) = try setup("""
        wavecode_0_enabled=1
        wavecode_0_samples=4
        wavecode_0_r=0.25
        wave_0_init1=t3 = 7; acc = 0;
        wave_0_per_frame1=t3 = t3 + 1; r = r + 0.5; frames = frames + 1;
        wave_0_per_point1=acc = acc + 1; x = sample;
        """)
        let wave = try #require(geometry.waves.first)
        let batch = GeometryBatch(), levels = audio()
        for round in 1...2 {
            batch.reset()
            wave.add(to: batch, q: eq.q, waveScale: 1, frame: frame, audio: levels, alpha: 0.5)
            #expect(wave.eq.scope["t3"] == 8)
            #expect(wave.eq.scope["r"] == 0.75)
            #expect(wave.eq.scope["frames"] == Double(round))
            #expect(wave.eq.scope["acc"] == Double(4 * round))  // per-point changes carry over
        }
        #expect(batch.draws.count == 1 && batch.draws[0].primitive == .lineStrip && batch.draws[0].count == 7)
        let first = batch.vertices[0], last = batch.vertices[6]
        #expect(abs(first.position.x + 1 / 0.625) < 1e-5 && abs(last.position.x - 1 / 0.625) < 1e-5)
        #expect(first.color.w == 0.5 && abs(first.color.x - 0.75) < 1e-6)
    }

    @Test func basicWaveModesAndBlends() {
        let wave = BasicWave(), batch = GeometryBatch(), levels = audio()
        for mode in 0..<8 {
            for old in 0..<8 {
                batch.reset()
                var values = PresetKeys.preset
                values["wave_mode"] = Double(mode)
                values["old_wave_mode"] = Double(old)
                wave.add(to: batch, values: values, blendProgress: 0.5, frame: frame, audio: levels)
                #expect(batch.draws.count == (mode == 7 ? 2 : 1))
                #expect(batch.vertices.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
            }
        }
    }

    @Test func bordersAndMotionVectors() {
        let batch = GeometryBatch()
        var values = PresetKeys.preset
        values["ob_a"] = 1
        values["ib_a"] = 1
        values["darken_center"] = 1
        Borders.add(to: batch, values: values, frame: frame)
        #expect(batch.draws.map(\.count) == [12, 24, 24])
        batch.reset()
        var mesh = WarpMesh(size: SIMD2(8, 6))
        let eq = try? PresetEquations(PresetFile.parse("[preset00]\nzoom=1.1", name: "T"), globals: EELGlobals(), frame: frame)
        if let eq { mesh.update(eq, time: 0, aspect: frame.aspect) }
        MotionVectors.add(to: batch, values: values, mesh: mesh, frame: frame)
        #expect(batch.vertices.count == 2 * 11 * 8)  // the last row and column fall on the edge
    }

    @Test func pipelinesCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try FixedShaders.library(device: device, extra: [])
        #expect(FrameGeometry(device: device, library: library) != nil)
    }

    @Test func bundledPresetsDrawAFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let library = try FixedShaders.library(device: device, extra: [])
        let geometry = try #require(FrameGeometry(device: device, library: library))
        let targets = try #require(Targets(device: device, size: SIMD2(320, 200)))
        let folder = try #require(MilkDropResources.presets)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "milk" }
        let globals = EELGlobals(), levels = audio()
        var mesh = WarpMesh(size: SIMD2(48, 36))
        var previous: FrameGeometry.Part?
        let arenas = FrameArenas(device: device)
        var cpu = 0.0, slowest = (0.0, "")
        for file in files.sorted(by: { $0.path < $1.path }) {
            var preset = try PresetFile.load(file)
            preset.values["old_wave_mode"] = previous?.equations.preset.values["wave_mode"] ?? 0
            let eq = try PresetEquations(preset, globals: globals, frame: frame)
            let part = (try PresetGeometry(preset, globals: globals, frame: frame), eq)
            eq.runFrame(frame)
            previous?.equations.runFrame(frame)
            mesh.update(eq, time: frame.time, aspect: frame.aspect)
            let buffer = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = targets.target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: pass))
            arenas.begin(buffer)
            let start = Date()
            geometry.encode(encoder, arena: arenas, prev: targets.prev, current: part, previous: previous, blendProgress: 0.4,
                            mixed: eq.values, frame: frame, audio: levels, mesh: mesh)
            let took = Date().timeIntervalSince(start)
            cpu += took
            if took > slowest.0 { slowest = (took, file.lastPathComponent) }
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            #expect(buffer.status == .completed, "\(file.lastPathComponent): \(String(describing: buffer.error))")
            previous = part
        }
        print("geometry CPU for \(files.count) blended frames: \(cpu) s, slowest \(slowest)")
    }
}
