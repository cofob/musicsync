import Foundation
import simd

/// Per-frame values the renderer knows; `ShaderUniforms(frame)` derives the rest.
public struct ShaderFrame: Sendable {
    /// Render texture size in pixels.
    public var size = SIMD2<Float>(1, 1)
    /// aspectx, aspecty as butterchurn computes them.
    public var aspect = SIMD2<Float>(1, 1)
    public var time: Float = 0, fps: Float = 60, frame: Float = 0, progress: Float = 1
    public var bass: Float = 1, mid: Float = 1, treb: Float = 1, vol: Float = 1
    public var bassAtt: Float = 1, midAtt: Float = 1, trebAtt: Float = 1, volAtt: Float = 1
    /// q1...q32; missing values read as 0.
    public var q = [Float](repeating: 0, count: 32)
    public var randPreset = SIMD4<Float>(0, 0, 0, 0)
    /// New random values each frame.
    public var randFrame = SIMD4<Float>(.random(in: 0..<1), .random(in: 0..<1), .random(in: 0..<1), .random(in: 0..<1))
    public var decay: Float = 0.98, gammaAdj: Float = 2, echoZoom: Float = 2, echoAlpha: Float = 0, echoOrient: Float = 0, fShader: Float = 0
    public var invert = false, brighten = false, darken = false, solarize = false
    /// Already clamped by the renderer as MilkDrop does.
    public var blurMin = SIMD3<Float>(0, 0, 0), blurMax = SIMD3<Float>(1, 1, 1)
    /// Same order as `TranslatedShader.userTextures`.
    public var userTextureSizes: [SIMD2<Float>] = []

    public init() {}
}

/// Four rotation matrices per group: static, slow, fast, very fast, ultra fast, random each frame.
public typealias ShaderRotations = (
    simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
    simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4,
    simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4
)

/// `texsize_<name>` of each user texture.
public typealias ShaderUserTexsizes = (
    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
)

/// The fragment (and vertex) `buffer(1)` of every translated shader, laid out exactly as the MSL `ShaderUniforms`.
public struct ShaderUniforms: Sendable {
    public var texsize, aspect, timing, audio, audioAtt: SIMD4<Float>
    public var qa, qb, qc, qd, qe, qf, qg, qh: SIMD4<Float>
    public var randPreset, randFrame: SIMD4<Float>
    public var roamCos, roamSin, slowRoamCos, slowRoamSin: SIMD4<Float>
    public var blurMin, blurMax, blurScale, blurBias: SIMD4<Float>
    public var texsizeNoiseLQ, texsizeNoiseMQ, texsizeNoiseHQ, texsizeNoiseLQLite, texsizeNoiseVolLQ, texsizeNoiseVolHQ: SIMD4<Float>
    /// decay, gammaAdj, echoZoom, echoAlpha.
    public var compA: SIMD4<Float>
    /// echoOrient, fShader, 0, 0.
    public var compB: SIMD4<Float>
    /// invert, brighten, darken, solarize as 0 or 1.
    public var compFlags: SIMD4<Float>
    /// Each is the column-vector form of MilkDrop's float4x3 matrix; the shader reads the top three rows.
    public var rot: ShaderRotations
    public var texsizeUser: ShaderUserTexsizes

    public init(_ f: ShaderFrame) {
        func size(_ s: SIMD2<Float>) -> SIMD4<Float> { SIMD4(s.x, s.y, 1 / s.x, 1 / s.y) }
        func roam(_ fn: (Float) -> Float, _ speeds: SIMD4<Float>) -> SIMD4<Float> {
            SIMD4(0.5 + 0.5 * fn(speeds.x * f.time), 0.5 + 0.5 * fn(speeds.y * f.time), 0.5 + 0.5 * fn(speeds.z * f.time), 0.5 + 0.5 * fn(speeds.w * f.time))
        }
        let q = f.q + [Float](repeating: 0, count: max(0, 32 - f.q.count))
        let qv = (0..<8).map { SIMD4(q[$0 * 4], q[$0 * 4 + 1], q[$0 * 4 + 2], q[$0 * 4 + 3]) }
        let fast = SIMD4<Float>(0.3, 1.3, 5, 20), slow = SIMD4<Float>(0.005, 0.008, 0.013, 0.022)
        let noise = SIMD4<Float>(256, 256, 1.0 / 256, 1.0 / 256), noiseLite = SIMD4<Float>(32, 32, 1.0 / 32, 1.0 / 32)
        texsize = size(f.size)
        aspect = size(f.aspect)
        timing = SIMD4(f.time, f.fps, f.frame, f.progress)
        audio = SIMD4(f.bass, f.mid, f.treb, f.vol)
        audioAtt = SIMD4(f.bassAtt, f.midAtt, f.trebAtt, f.volAtt)
        (qa, qb, qc, qd, qe, qf, qg, qh) = (qv[0], qv[1], qv[2], qv[3], qv[4], qv[5], qv[6], qv[7])
        randPreset = f.randPreset
        randFrame = f.randFrame
        roamCos = roam(cos, fast)
        roamSin = roam(sin, fast)
        slowRoamCos = roam(cos, slow)
        slowRoamSin = roam(sin, slow)
        blurMin = SIMD4(f.blurMin, 0)
        blurMax = SIMD4(f.blurMax, 0)
        blurScale = blurMax - blurMin
        blurBias = blurMin
        (texsizeNoiseLQ, texsizeNoiseMQ, texsizeNoiseHQ) = (noise, noise, noise)
        (texsizeNoiseLQLite, texsizeNoiseVolLQ, texsizeNoiseVolHQ) = (noiseLite, noiseLite, noiseLite)
        compA = SIMD4(f.decay, f.gammaAdj, f.echoZoom, f.echoAlpha)
        compB = SIMD4(f.echoOrient, f.fShader, 0, 0)
        compFlags = SIMD4(f.invert ? 1 : 0, f.brighten ? 1 : 0, f.darken ? 1 : 0, f.solarize ? 1 : 0)
        let identity = matrix_identity_float4x4
        rot = (identity, identity, identity, identity, identity, identity, identity, identity, identity, identity, identity, identity,
               identity, identity, identity, identity, identity, identity, identity, identity, identity, identity, identity, identity)
        let zero = SIMD4<Float>(0, 0, 0, 0)
        texsizeUser = (zero, zero, zero, zero, zero, zero, zero, zero, zero, zero, zero, zero, zero, zero, zero, zero)
        let rotations = Self.rotations(time: f.time, seed: f.randPreset)
        withUnsafeMutableBytes(of: &rot) { raw in
            for (i, m) in rotations.enumerated() { raw.storeBytes(of: m, toByteOffset: i * MemoryLayout<simd_float4x4>.stride, as: simd_float4x4.self) }
        }
        withUnsafeMutableBytes(of: &texsizeUser) { raw in
            for (i, s) in f.userTextureSizes.prefix(16).enumerated() { raw.storeBytes(of: size(s), toByteOffset: i * 16, as: SIMD4<Float>.self) }
        }
    }

    /// MilkDrop's rot_* matrices: random base angles, speeds and translations per preset (here derived from `seed`,
    /// i.e. rand_preset), speed scaled by `0.9 * (i / 8)^3.2`; rot_rand1...4 are new every frame.
    static func rotations(time: Float, seed: SIMD4<Float>) -> [simd_float4x4] {
        var state = seed.scalars.reduce(UInt64(0x9E37_79B9_7F4A_7C15)) { $0 &* 31 &+ UInt64($1.bitPattern) }
        func next() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
        }
        func vector(_ rand: () -> Float) -> SIMD3<Float> { SIMD3(rand(), rand(), rand()) }
        func matrix(angles: SIMD3<Float>, translation: SIMD3<Float>) -> simd_float4x4 {
            let x = simd_float4x4(simd_quatf(angle: angles.x, axis: SIMD3(1, 0, 0)))
            let y = simd_float4x4(simd_quatf(angle: angles.y, axis: SIMD3(0, 1, 0)))
            let z = simd_float4x4(simd_quatf(angle: angles.z, axis: SIMD3(0, 0, 1)))
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4(translation, 1)
            return y * z * t * x
        }
        var out: [simd_float4x4] = (0..<20).map { i in
            let translation = vector(next) * 2 - 1
            let base = vector(next) * 6.28
            let speed = (vector(next) * 2 - 1) * (0.9 * pow(Float(i) / 8, 3.2))
            return matrix(angles: base + speed * time, translation: translation)
        }
        let random = { Float.random(in: 0..<1) }
        for _ in 0..<4 { out.append(matrix(angles: vector(random) * 6.28, translation: vector(random))) }
        return out
    }
}

extension SIMD4 {
    fileprivate var scalars: [Scalar] { [x, y, z, w] }
}
