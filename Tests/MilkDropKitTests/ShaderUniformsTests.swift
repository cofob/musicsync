import Metal
@testable import MilkDropKit
import simd
import Testing

@Suite struct ShaderUniformsTests {
    @Test func derivedValues() {
        var frame = ShaderFrame()
        frame.size = SIMD2(800, 400)
        frame.aspect = SIMD2(0.5, 1)
        frame.q = (1...32).map(Float.init)
        frame.blurMin = SIMD3(0.1, 0.2, 0.3)
        frame.blurMax = SIMD3(0.9, 0.8, 0.7)
        frame.userTextureSizes = [SIMD2(256, 128)]
        frame.invert = true
        let u = ShaderUniforms(frame)
        #expect(u.texsize == SIMD4(800, 400, 1.0 / 800, 1.0 / 400))
        #expect(u.aspect == SIMD4(0.5, 1, 2, 1))
        #expect(u.qa == SIMD4(1, 2, 3, 4) && u.qh == SIMD4(29, 30, 31, 32))
        #expect(abs(u.blurScale.x - 0.8) < 1e-6 && u.blurBias.z == 0.3)
        #expect(u.roamCos == SIMD4(1, 1, 1, 1) && u.slowRoamSin == SIMD4(0.5, 0.5, 0.5, 0.5))
        #expect(u.texsizeNoiseLQ == SIMD4(256, 256, 1.0 / 256, 1.0 / 256) && u.texsizeNoiseVolHQ.x == 32)
        #expect(u.compA == SIMD4(0.98, 2, 2, 0) && u.compFlags == SIMD4(1, 0, 0, 0))
        #expect(u.texsizeUser.0 == SIMD4(256, 128, 1.0 / 256, 1.0 / 128) && u.texsizeUser.1 == .zero)
        #expect(u.randFrame != ShaderUniforms(frame).randFrame)
    }

    @Test func rotationsAreStablePerPresetAndMoveWithTime() {
        let seed = SIMD4<Float>(0.1, 0.2, 0.3, 0.4)
        let a = ShaderUniforms.rotations(time: 1, seed: seed)
        let b = ShaderUniforms.rotations(time: 1, seed: seed)
        let later = ShaderUniforms.rotations(time: 50, seed: seed)
        #expect(a.count == 24)
        #expect(a[0] == later[0]) // rot_s1 never moves
        #expect(a[5] == b[5] && a[19] != later[19])
        #expect(a[5] != ShaderUniforms.rotations(time: 1, seed: seed + 1)[5])
        func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
        let r = simd_float3x3(columns: (xyz(a[7].columns.0), xyz(a[7].columns.1), xyz(a[7].columns.2)))
        #expect(abs(r.determinant - 1) < 1e-4)
    }

    /// The Swift struct must match the MSL `ShaderUniforms` byte for byte.
    @Test func layoutMatchesMSL() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let shader = try HLSLTranslator.translate("shader_body { ret = texsize.xyz + rot_rand4[0].xyz + texsize_x.x; }", stage: .warp)
        let library = try device.makeLibrary(source: shader.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "md_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "md_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        var reflection: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
        let binding = try #require(reflection?.fragmentBindings.first { $0.type == .buffer && $0.index == 1 } as? MTLBufferBinding)
        #expect(binding.bufferDataSize == MemoryLayout<ShaderUniforms>.size)
        let members = try #require(binding.bufferStructType?.members)
        let offsets = Dictionary(uniqueKeysWithValues: members.map { ($0.name, $0.offset) })
        #expect(offsets["comp_flags"] == MemoryLayout<ShaderUniforms>.offset(of: \.compFlags))
        #expect(offsets["rot"] == MemoryLayout<ShaderUniforms>.offset(of: \.rot))
        #expect(offsets["texsize_user"] == MemoryLayout<ShaderUniforms>.offset(of: \.texsizeUser))
    }
}
