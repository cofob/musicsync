import Foundation

/// One custom wave of a preset (`wavecode_N`), as butterchurn's `drawCustomWaveform`: per-frame code, a smoothed
/// stretch of the waveform or spectrum, per-point code for each sample, then a line strip (smoothed to 2n − 1
/// points) or dots. Variables that per-point code leaves carry over to the next point and frame.
final class CustomWave {
    private enum Key: Int, CaseIterable {
        case samples, sep, scaling, spectrum, smoothing, usedots, thick, additive, r, g, b, a, sample, value1, value2, x, y
    }

    let eq: ElementEquations
    private let frameCode: EELProgram, pointCode: EELProgram
    private let slots: [Int]
    private var left = [Double](repeating: 0, count: 512), right = [Double](repeating: 0, count: 512)
    private var points = [GeometryVertex](repeating: GeometryVertex(position: .zero, color: .zero), count: 512)

    init(_ wave: Preset.Wave, globals: EELGlobals, frame: FrameGlobals, random: @escaping () -> Double) throws {
        eq = try ElementEquations(values: wave.values, initCode: wave.initCode, globals: globals, frame: frame, random: random)
        frameCode = eq.scope.compileOrSkip(wave.frameCode)
        pointCode = eq.scope.compileOrSkip(wave.pointCode)
        slots = Key.allCases.map { [scope = eq.scope] in scope.slot("\($0)") }
    }

    /// Adds the wave. `q`: the main preset's; `waveScale`: its file `wave_scale`; `alpha`: the preset's share.
    func add(to batch: GeometryBatch, q: [Double], waveScale: Double, frame: FrameGlobals, audio: AudioLevels, alpha: Double) {
        let scope = eq.scope
        func v(_ key: Key) -> Double { scope[slots[key.rawValue]] }
        func set(_ key: Key, _ value: Double) { scope[slots[key.rawValue]] = value }
        eq.beginFrame(q: q, frame: frame)
        scope.run(frameCode)
        guard let sep = v(.sep).floorInt, let total = v(.samples).floorInt.map({ min($0, 512) }) else { return }
        let samples = min(total - sep, 512)
        let dots = v(.usedots) != 0
        guard samples >= 2 || (dots && samples >= 1) else { return }
        let spectrum = v(.spectrum) != 0
        let scale = (spectrum ? 0.15 : 0.004) * v(.scaling) * waveScale
        let (l, r) = spectrum ? (audio.spectrumLeft, audio.spectrumRight) : (audio.waveLeft, audio.waveRight)
        let startL = spectrum ? 0 : Int((Double(512 - samples) / 2 - Double(sep) / 2).rounded(.down))
        let startR = spectrum ? 0 : Int((Double(512 - samples) / 2 + Double(sep) / 2).rounded(.down))
        let step = spectrum ? Double(512 - sep) / Double(samples) : 1
        let w = (0.98 * v(.smoothing)).squareRoot(), u = 1 - w
        func at(_ data: [Float], _ i: Double) -> Double {
            guard let i = i.floorInt, data.indices.contains(i) else { return .nan }
            return Double(data[i])
        }
        left[0] = at(l, Double(startL))
        right[0] = at(r, Double(startR))
        for m in 1..<max(samples, 1) {
            left[m] = at(l, Double(m) * step + Double(startL)) * u + left[m - 1] * w
            right[m] = at(r, Double(m) * step + Double(startR)) * u + right[m - 1] * w
        }
        for m in stride(from: samples - 2, through: 0, by: -1) {
            left[m] = left[m] * u + left[m + 1] * w
            right[m] = right[m] * u + right[m + 1] * w
        }
        let (cr, cg, cb, ca) = (v(.r), v(.g), v(.b), v(.a))
        let inv = SIMD2(1 / frame.aspect.x, 1 / frame.aspect.y)
        for m in 0..<samples {
            let d = left[m] * scale, e = right[m] * scale
            set(.sample, Double(m) / Double(samples - 1))
            set(.value1, d); set(.value2, e)
            set(.x, 0.5 + d); set(.y, 0.5 + e)
            set(.r, cr); set(.g, cg); set(.b, cb); set(.a, ca)
            scope.run(pointCode)
            points[m] = GeometryVertex(position: SIMD2(Float((2 * v(.x) - 1) * inv.x), Float((-2 * v(.y) + 1) * inv.y)),
                                       color: SIMD4(Float(v(.r)), Float(v(.g)), Float(v(.b)), Float(v(.a) * alpha)))
        }
        let thick = v(.thick) != 0, additive = v(.additive) != 0, big: Float = frame.pixels.x >= 1024 ? 1 : 0
        let start = batch.vertices.count
        if v(.usedots) != 0 {
            for m in 0..<samples { batch.append(points[m]) }
            batch.draw(.point, from: start, additive: additive, pointSize: (thick ? 2 : 1) + big)
        } else {
            Self.smooth(points, count: samples, into: batch)
            let pixel = SIMD2(2 / Float(frame.pixels.x), 2 / Float(frame.pixels.y))
            batch.draw(.lineStrip, from: start, additive: additive, thick: thick ? pixel : nil)
        }
    }

    /// Butterchurn's `smoothWaveAndColor`: a point between each pair, from the four around it; it takes the color of
    /// the point before it.
    static func smooth(_ p: [GeometryVertex], count n: Int, into batch: GeometryBatch) {
        var before = 0, next = 1
        for i in 0..<n - 1 {
            let after = next
            next = min(n - 1, i + 2)
            batch.append(p[i])
            let mid = 0.5 * (-0.15 * p[before].position + 1.15 * p[i].position + 1.15 * p[after].position - 0.15 * p[next].position)
            batch.append(GeometryVertex(position: mid, color: p[i].color))
            before = i
        }
        batch.append(p[n - 1])
    }
}
