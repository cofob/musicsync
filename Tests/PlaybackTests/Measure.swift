import Accelerate
@testable import Playback

/// Objective checks of rendered audio in place of listening: levels, gaps, clipping, beat offsets, band gains, clicks.
enum Measure {
    static func mono(_ stereo: [Float]) -> [Float] {
        (0..<stereo.count / 2).map { (stereo[2 * $0] + stereo[2 * $0 + 1]) / 2 }
    }

    static func dB(_ power: Double) -> Double { 10 * log10(max(power, 1e-12)) }

    /// Level in dB full scale (mean square of both channels) of `window` seconds every `hop` seconds.
    static func levels(_ stereo: [Float], sampleRate: Double, window: Double = 0.4, hop: Double = 0.1) -> [Double] {
        let n = Int(window * sampleRate), h = Int(hop * sampleRate), frames = stereo.count / 2
        guard frames >= n else { return [] }
        return stereo.withUnsafeBufferPointer { s in
            stride(from: 0, through: frames - n, by: h).map { dB(Double(vDSP.meanSquare(UnsafeBufferPointer(rebasing: s[2 * $0..<2 * ($0 + n)])))) }
        }
    }

    /// Longest run of 5 ms blocks below `threshold` dB, in seconds.
    static func longestSilence(_ stereo: [Float], sampleRate: Double, threshold: Double = -60) -> Double {
        let quiet = levels(stereo, sampleRate: sampleRate, window: 0.005, hop: 0.005).map { $0 < threshold }
        var longest = 0, run = 0
        for q in quiet { run = q ? run + 1 : 0; longest = max(longest, run) }
        return Double(longest) * 0.005
    }

    static func peak(_ samples: [Float]) -> Float { samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples) }

    /// Lag of `b` against `a` in steps (positive: `b` is later), within `lags`, at the peak of the cross-correlation.
    static func lag(_ a: [Float], _ b: [Float], lags: ClosedRange<Int>) -> Double {
        let scores: [Double] = lags.map { l in
            let lo = max(0, -l), hi = min(a.count, b.count - l)
            return lo < hi ? (lo..<hi).reduce(0.0) { $0 + Double(a[$1]) * Double(b[$1 + l]) } : 0
        }
        guard let i = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return 0 }
        var x = Double(lags.lowerBound + i)
        if i > 0, i < scores.count - 1 {
            let (p, q, r) = (scores[i - 1], scores[i], scores[i + 1]), d = p - 2 * q + r
            if d < 0 { x += 0.5 * (p - r) / d }
        }
        return x
    }

    /// Rises of the mean magnitude of the second difference (a steep high-pass, so steady low tones do not count)
    /// in 1 ms bins: sharp at clicks and beats.
    static func envelope(_ mono: [Float], sampleRate: Double) -> [Float] {
        let n = max(Int(sampleRate / 1000), 1)
        let high = mono.indices.map { $0 < 2 ? 0 : abs(mono[$0] - 2 * mono[$0 - 1] + mono[$0 - 2]) }
        let mean = (0..<mono.count / n).map { k in high[k * n..<(k + 1) * n].reduce(0, +) / Float(n) }
        return mean.indices.map { $0 == 0 ? 0 : max(0, mean[$0] - mean[$0 - 1]) }
    }

    /// Onset strength every 128 frames (`Beat.onsets`), as AutoMix hears beats.
    static func onsets(_ stereo: [Float]) -> [Float] { Beat.onsets(mono(stereo)) }

    /// Milliseconds the beats of `incoming` are late against those of `outgoing`, in windows of `window` seconds,
    /// within half a beat of `bpm`.
    static func beatOffsets(_ outgoing: [Float], _ incoming: [Float], sampleRate: Double, bpm: Double, window: Double = 4) -> [Double] {
        let hop = Double(Beat.hop) / sampleRate, n = Int(window * sampleRate) * 2
        return stride(from: 0, through: outgoing.count - n, by: n).map { start in
            let a = onsets(Array(outgoing[start..<start + n])), b = onsets(Array(incoming[start..<start + n]))
            let half = Int(30 / bpm / hop)
            return lag(a, b, lags: -half...half) * hop * 1000
        }
    }

    /// Largest change of `rate` within any 50 ms, from timed samples.
    static func maxRateStep(_ samples: [(time: Double, rate: Double)]) -> Double {
        var worst = 0.0, j = 0
        for i in samples.indices {
            while j < samples.count, samples[j].time < samples[i].time + 0.05 { worst = max(worst, abs(samples[j].rate - samples[i].rate)); j += 1 }
            j = max(j - 1, i)
        }
        return worst
    }

    /// Mean power per FFT bin over 8192-frame Hann windows, half overlapping.
    static func spectrum(_ mono: [Float]) -> [Double] {
        let size = 8192, half = size / 2
        guard mono.count >= size, let fft = vDSP.FFT(log2n: 13, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        var power = [Double](repeating: 0, count: half), count = 0
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        for start in stride(from: 0, through: mono.count - size, by: half) {
            let frame = vDSP.multiply(Array(mono[start..<start + size]), hann)
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    fft.forward(input: split, output: &split)
                }
            }
            for k in 1..<half { power[k] += Double(real[k] * real[k] + imag[k] * imag[k]) }
            count += 1
        }
        return power.map { $0 / Double(max(count, 1)) }
    }

    /// FFT bins within a sixth of an octave of `frequency`.
    static func bins(_ frequency: Double, sampleRate: Double, count: Int) -> ClosedRange<Int> {
        let width = sampleRate / 8192, edge = pow(2, 1.0 / 6)
        let lo = max(Int((frequency / edge / width).rounded(.up)), 1), hi = min(Int((frequency * edge / width).rounded(.down)), count - 1)
        return lo...max(lo, hi)
    }

    /// Gain in dB of `output` over `input` in the band around each frequency.
    static func bandGains(input: [Float], output: [Float], sampleRate: Double, frequencies: [Double] = EqualizerGains.frequencies) -> [Double] {
        let a = spectrum(input), b = spectrum(output)
        return frequencies.map { f in
            let r = bins(f, sampleRate: sampleRate, count: min(a.count, b.count))
            return dB(r.reduce(0) { $0 + b[$1] } / r.reduce(0) { $0 + a[$1] })
        }
    }

    /// What the equalizer filters should give in the same bands, for a flat input.
    static func expectedGains(_ gains: EqualizerGains, sampleRate: Double, frequencies: [Double] = EqualizerGains.frequencies) -> [Double] {
        let filters = gains.bands.enumerated().map { Biquad.peaking(frequency: EqualizerGains.frequencies[$0], gain: $1, q: EqualizerProcessor.q, sampleRate: sampleRate) }
        return frequencies.map { f in
            let r = bins(f, sampleRate: sampleRate, count: 4096)
            let power = r.map { k in filters.reduce(1.0) { $0 * $1.power(at: Double(k) * sampleRate / 8192, sampleRate: sampleRate) } }
            return dB(power.reduce(0, +) / Double(power.count)) + gains.preamp
        }
    }

    /// Largest sample-to-sample jump of a 10 ms block against the median of the blocks within 0.5 s around it:
    /// about 1 for a smooth signal, far more at a click. Also the time of that block.
    static func clickRatio(_ mono: [Float], sampleRate: Double) -> (ratio: Double, at: Double) {
        let n = Int(sampleRate / 100)
        let jumps = (0..<mono.count / n).map { k in
            (max(k * n, 1)..<(k + 1) * n).reduce(Float(0)) { max($0, abs(mono[$1] - mono[$1 - 1])) }
        }
        var worst = (ratio: 0.0, at: 0.0)
        for k in jumps.indices {
            let near = jumps[max(0, k - 50)..<min(jumps.count, k + 51)].sorted()
            let ratio = Double(jumps[k]) / Double(max(near[near.count / 2], 1e-9))
            if ratio > worst.ratio { worst = (ratio, Double(k * n) / sampleRate) }
        }
        return worst
    }
}

extension Biquad {
    /// |H|² at `frequency`.
    func power(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return (nr * nr + ni * ni) / (dr * dr + di * di)
    }
}
