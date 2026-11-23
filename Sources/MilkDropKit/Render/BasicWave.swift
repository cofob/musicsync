import Foundation

/// MilkDrop's built-in waveform (`wave_mode` 0…7), as butterchurn's `drawBasicWaveform`. While blending into a preset
/// of another mode, the old mode's points are made too and mixed into the new ones.
final class BasicWave {
    private struct Params {
        var waveA = 0.0, mystery = 0.0, x = 0.0, y = 0.0, time = 0.0, volume = 0.0, treb = 0.0
        var modByVolume = 0.0, modStart = 0.0, modEnd = 0.0, texsizeX = 0.0
        var aspect = SIMD2<Double>(1, 1)
    }

    private var left = [Double](repeating: 0, count: 512), right = [Double](repeating: 0, count: 512)
    private var positions = [SIMD2<Double>](repeating: .zero, count: 512), positions2 = [SIMD2<Double>](repeating: .zero, count: 512)
    private var old = [SIMD2<Double>](repeating: .zero, count: 512), old2 = [SIMD2<Double>](repeating: .zero, count: 512)

    /// `values`: the (mixed) per-frame values; `blendProgress`: the new preset's linear share while blending, else nil.
    func add(to batch: GeometryBatch, values: [String: Double], blendProgress: Double?, frame: FrameGlobals, audio: AudioLevels) {
        func v(_ name: String) -> Double { values[name] ?? 0 }
        let volume = (frame.bass + frame.mid + frame.treb) / 3
        guard volume > -0.01, v("wave_a") > 0.001 else { return }
        Self.process(audio.waveLeft, values, into: &left)
        Self.process(audio.waveRight, values, into: &right)
        let p = Params(waveA: v("wave_a"), mystery: v("wave_mystery"), x: 2 * v("wave_x") - 1, y: 2 * v("wave_y") - 1,
                       time: frame.time, volume: volume, treb: frame.treb, modByVolume: v("modwavealphabyvolume"),
                       modStart: v("modwavealphastart"), modEnd: v("modwavealphaend"), texsizeX: Double(frame.pixels.x),
                       aspect: frame.aspect)
        guard let mode = v("wave_mode").floorInt.map({ $0 % 8 }),
              let generated = Self.generate(mode, p, left, right, &positions, &positions2) else { return }
        let (count, newAlpha) = generated
        let oldMode = v("old_wave_mode").floorInt.map { $0 % 8 } ?? mode
        var alpha = newAlpha
        let mix = 0.5 - 0.5 * cos((blendProgress ?? 0) * .pi), keep = 1 - mix
        if blendProgress != nil, oldMode != mode, case let (oldCount, oldAlpha)? = Self.generate(oldMode, p, left, right, &old, &old2),
           oldCount > 0 {
            alpha = mix * newAlpha + keep * oldAlpha
            func oldAt(_ a: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
                let i = Int(t), f = t - Double(i)
                return a[i] * (1 - f) + a[min(i + 1, 511)] * f
            }
            if mode == 7 {
                let step = Double(oldCount - 1) / Double(2 * count)
                for i in 0..<count {
                    positions[i] = positions[i] * mix + oldAt(old, Double(i) * step) * keep
                    positions2[i] = positions2[i] * mix + oldAt(old, Double(i + count) * step) * keep
                }
            } else if oldMode == 7 {
                // Only the first half mixes, as in butterchurn; the second line is not drawn for other modes.
                let half = Double(count) / 2, step = Double(oldCount - 1) / half
                for i in 0..<Int(half.rounded(.up)) {
                    positions[i] = positions[i] * mix + oldAt(old, Double(i) * step) * keep
                }
            } else {
                let step = Double(oldCount - 1) / Double(count)
                for i in 0..<count { positions[i] = positions[i] * mix + oldAt(old, Double(i) * step) * keep }
            }
        }
        var r = v("wave_r").clamped(0, 1), g = v("wave_g").clamped(0, 1), b = v("wave_b").clamped(0, 1)
        if v("wave_brighten") != 0 {
            let m = max(r, g, b)
            if m > 0.01 { (r, g, b) = (r / m, g / m, b / m) }
        }
        let color = SIMD4(Float(r), Float(g), Float(b), Float(alpha))
        let dots = v("wave_dots") != 0, additive = v("additivewave") != 0
        let thick = dots || v("wave_thick") != 0 ? SIMD2(2 / Float(frame.pixels.x), 2 / Float(frame.pixels.y)) : nil
        for line in mode == 7 ? [positions, positions2] : [positions] {
            let start = batch.vertices.count
            Self.smooth(line, count: count, color: color, into: batch)
            batch.draw(dots ? .point : .lineStrip, from: start, additive: additive, thick: thick)
        }
    }

    /// Butterchurn's `processWaveform`: scaled by `wave_scale` / 128, smoothed one way by `wave_smoothing`.
    private static func process(_ wave: [Float], _ values: [String: Double], into out: inout [Double]) {
        let scale = (values["wave_scale"] ?? 1) / 128, smoothing = values["wave_smoothing"] ?? 0, k = scale * (1 - smoothing)
        out[0] = Double(wave[0]) * scale
        for i in 1..<512 { out[i] = Double(wave[i]) * k + out[i - 1] * smoothing }
    }

    /// Butterchurn's `smoothWave` of the first `count` points, y flipped as butterchurn does before it.
    private static func smooth(_ p: [SIMD2<Double>], count n: Int, color: SIMD4<Float>, into batch: GeometryBatch) {
        guard n > 0 else { return }
        func add(_ q: SIMD2<Double>) { batch.append(GeometryVertex(position: SIMD2(Float(q.x), Float(-q.y)), color: color)) }
        var before = 0, next = 1
        for i in 0..<n - 1 {
            let after = next
            next = min(n - 1, i + 2)
            add(p[i])
            add(0.5 * (-0.15 * p[before] + 1.15 * p[i] + 1.15 * p[after] - 0.15 * p[next]))
            before = i
        }
        add(p[n - 1])
    }

    /// Points of one mode into `out` (and `out2` for mode 7's second line); returns their count and the alpha.
    private static func generate(_ mode: Int, _ p: Params, _ n: [Double], _ l: [Double],
                                 _ out: inout [SIMD2<Double>], _ out2: inout [SIMD2<Double>]) -> (Int, Double)? {
        var v = p.mystery
        if mode == 0 || mode == 1 || mode == 4, v < -1 || v > 1 {
            v = 0.5 * v + 0.5
            v -= v.rounded(.down)
            v = 2 * abs(v) - 1
        }
        let (g, c, ax, ay) = (p.x, p.y, p.aspect.x, p.aspect.y)
        var a = p.waveA
        func volume() {
            if p.modByVolume > 0 { a *= (p.volume - p.modStart) / (p.modEnd - p.modStart) }
            a = a.clamped(0, 1)
        }
        func bySize(_ small: Double, _ medium: Double, _ large: Double) -> Double {
            p.texsizeX < 1024 ? small : p.texsizeX < 2048 ? medium : large
        }
        var count = 0
        switch mode {
        case 0:
            volume()
            count = 257
            let step = 1 / Double(count - 1), offset = (512 - count) / 2
            for i in 0..<count - 1 {
                var r = 0.5 + 0.4 * l[i + offset] + v
                let ang = Double(i) * step * 2 * .pi + 0.2 * p.time
                if Double(i) < Double(count) / 10 {
                    let t = 0.5 - 0.5 * cos(Double(i) / (0.1 * Double(count)) * .pi)
                    r = (1 - t) * (0.5 + 0.4 * l[i + count + offset] + v) + r * t
                }
                out[i] = SIMD2(r * cos(ang) * ay + g, r * sin(ang) * ax + c)
            }
            out[count - 1] = out[0]
        case 1:
            a *= 1.25
            volume()
            count = 256
            for i in 0..<count {
                let r = 0.53 + 0.43 * l[i] + v, ang = 0.5 * n[i + 32] * .pi + 2.3 * p.time
                out[i] = SIMD2(r * cos(ang) * ay + g, r * sin(ang) * ax + c)
            }
        case 2, 3:
            if mode == 2 {
                a *= bySize(0.09, 0.11, 0.13)
            } else {
                a *= bySize(0.15, 0.22, 0.33) * 1.3 * p.treb * p.treb
            }
            volume()
            count = 512
            for i in 0..<count { out[i] = SIMD2(l[i] * ay + g, n[(i + 32) % 512] * ax + c) }
        case 4:
            volume()
            count = Double(512) > p.texsizeX / 3 ? Int(p.texsizeX / 3) : 512
            let step = 1 / Double(count), offset = (512 - count) / 2
            let k = 0.45 + 0.5 * (0.5 * v + 0.5), keep = 1 - k
            for i in 0..<count {
                var x = 2 * Double(i) * step + (g - 1) + 0.44 * l[(i + 25 + offset) % 512], y = 0.47 * n[i + offset] + c
                if i > 1 {
                    x = x * keep + k * (2 * out[i - 1].x - out[i - 2].x)
                    y = y * keep + k * (2 * out[i - 1].y - out[i - 2].y)
                }
                out[i] = SIMD2(x, y)
            }
        case 5:
            a *= bySize(0.09, 0.11, 0.13)
            volume()
            let cs = cos(0.3 * p.time), sn = sin(0.3 * p.time)
            count = 512
            for i in 0..<count {
                let j = (i + 32) % 512, x = l[i] * n[j] + n[i] * l[j], y = l[i] * l[i] - n[j] * n[j]
                // Butterchurn adds wave_x/y to the aspect here instead of to the point.
                out[i] = SIMD2((x * cs - y * sn) * (ay + g), (x * sn + y * cs) * (ax + c))
            }
        case 6, 7:
            volume()
            count = Double(256) > p.texsizeX / 3 ? Int(p.texsizeX / 3) : 256
            let offset = (512 - count) / 2, t = 0.5 * .pi * v
            var (ex, ey) = (cos(t), sin(t))
            var xs = [g * cos(t + 0.5 * .pi) - 3 * ex, g * cos(t + 0.5 * .pi) + 3 * ex]
            var ys = [g * sin(t + 0.5 * .pi) - 3 * ey, g * sin(t + 0.5 * .pi) + 3 * ey]
            for e in 0..<2 {
                for edge in 0..<4 {
                    let o = 1 - e
                    var f: Double?
                    switch edge {
                    case 0: if xs[e] > 1.1 { f = (1.1 - xs[o]) / (xs[e] - xs[o]) }
                    case 1: if xs[e] < -1.1 { f = (-1.1 - xs[o]) / (xs[e] - xs[o]) }
                    case 2: if ys[e] > 1.1 { f = (1.1 - ys[o]) / (ys[e] - ys[o]) }
                    default: if ys[e] < -1.1 { f = (-1.1 - ys[o]) / (ys[e] - ys[o]) }
                    }
                    if let f {
                        let dx = xs[e] - xs[o], dy = ys[e] - ys[o]
                        xs[e] = xs[o] + dx * f
                        ys[e] = ys[o] + dy * f
                    }
                }
            }
            ex = (xs[1] - xs[0]) / Double(count)
            ey = (ys[1] - ys[0]) / Double(count)
            let ang = atan2(ey, ex), nx = cos(ang + 0.5 * .pi), ny = sin(ang + 0.5 * .pi)
            if mode == 6 {
                for i in 0..<count {
                    let s = n[i + offset]
                    out[i] = SIMD2(xs[0] + ex * Double(i) + 0.25 * nx * s, ys[0] + ey * Double(i) + 0.25 * ny * s)
                }
            } else {
                let sep = pow(0.5 * c + 0.5, 2)
                for i in 0..<count {
                    let s = n[i + offset], s2 = l[i + offset]
                    out[i] = SIMD2(xs[0] + ex * Double(i) + nx * (0.25 * s + sep), ys[0] + ey * Double(i) + ny * (0.25 * s + sep))
                    out2[i] = SIMD2(xs[0] + ex * Double(i) + nx * (0.25 * s2 - sep), ys[0] + ey * Double(i) + ny * (0.25 * s2 - sep))
                }
            }
        default:
            return nil
        }
        return (count, a)
    }
}
