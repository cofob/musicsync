import Accelerate
import Foundation

/// Tempo and beat grid of a song from its onset strength (spectral flux of 46 ms frames every 11.6 ms at 11 kHz).
/// The autocorrelation gives a rough tempo, preferring tempos near 120 between its halves and doubles; folding the
/// onsets over the whole song at fine tempo steps then gives the exact tempo and the beat phase.
struct Beat {
    static let window = 512
    static let hop = 128
    static let tempos = 70.0...180.0

    var bpm = 120.0
    var downbeat: TimeInterval = 0
    var strength = 0.0

    init(_ samples: [Float], sampleRate: Double, soundStart: TimeInterval) {
        let onsets = Self.onsets(samples)
        let step = Double(Self.hop) / sampleRate
        guard onsets.count > 512, let rough = Self.roughTempo(onsets, step: step) else { return }
        let grid = stride(from: rough * 0.96, through: rough * 1.04, by: 0.05).map { Self.fold(onsets, step: step, bpm: $0) }
        guard let best = grid.max(by: { $0.score < $1.score }) else { return }
        bpm = min(max(best.bpm, Self.tempos.lowerBound), Self.tempos.upperBound)
        let period = 60 / best.bpm
        strength = Self.pulse(onsets, lag: period / step)
        let accents = (0..<4).map { Self.accent(onsets, step: step, from: best.phase + Double($0) * period, every: 4 * period) }
        let bar = accents.indices.max { accents[$0] < accents[$1] } ?? 0
        // A frame's onset is heard at its center; the flux rises about 10 ms before (measured on click tracks).
        let one = best.phase + Double(bar) * period + Double(Self.window / 2) / sampleRate + 0.01
        downbeat = one + (((soundStart - one) / (4 * period)).rounded(.up) * 4 * period)
        if downbeat - 4 * period >= soundStart - 0.05 { downbeat -= 4 * period }
    }

    /// Positive change of the log spectrum per hop, minus its local mean.
    static func onsets(_ samples: [Float]) -> [Float] {
        let count = samples.count >= window ? (samples.count - window) / hop + 1 : 0
        let half = window / 2
        guard count > 0, let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(window))), radix: .radix2, ofType: DSPSplitComplex.self)
        else { return [] }
        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: window, isHalfWindow: false)
        var flux = [Float](repeating: 0, count: count)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var previous = [Float](repeating: 0, count: half), magnitudes = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: window)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                for m in 0..<count {
                    samples.withUnsafeBufferPointer { s in
                        vDSP.multiply(UnsafeBufferPointer(rebasing: s[m * hop..<m * hop + window]), hann, result: &frame)
                    }
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    fft.forward(input: split, output: &split)
                    split.imagp[0] = 0  // packed Nyquist bin
                    vDSP.absolute(split, result: &magnitudes)
                    vDSP.multiply(100, magnitudes, result: &magnitudes)
                    var n = Int32(half)
                    magnitudes.withUnsafeMutableBufferPointer { vvlog1pf($0.baseAddress!, $0.baseAddress!, &n) }
                    var sum: Float = 0
                    for k in 1..<half { sum += max(0, magnitudes[k] - previous[k]) }
                    flux[m] = m == 0 ? 0 : sum
                    swap(&previous, &magnitudes)
                }
            }
        }
        var sums = [Float(0)]
        for f in flux { sums.append(sums[sums.count - 1] + f) }
        let reach = 43  // about 0.5 s
        return flux.indices.map { m in
            let lo = max(0, m - reach), hi = min(count, m + reach + 1)
            return max(0, flux[m] - (sums[hi] - sums[lo]) / Float(hi - lo))
        }
    }

    /// Tempo of the strongest autocorrelation peak, weighted toward 120 (one octave wide), refined between lags.
    static func roughTempo(_ onsets: [Float], step: Double) -> Double? {
        let lags = Int((60 / tempos.upperBound / step).rounded(.down))...Int((60 / tempos.lowerBound / step).rounded(.up))
        let n = onsets.count
        let acf: [Double] = onsets.withUnsafeBufferPointer { o in
            lags.map { lag in
                Double(vDSP.dot(UnsafeBufferPointer(rebasing: o[0..<n - lag]), UnsafeBufferPointer(rebasing: o[lag..<n]))) / Double(n - lag)
            }
        }
        let weighted = zip(lags, acf).map { lag, value in value * exp(-0.5 * pow(log2(60 / (Double(lag) * step) / 120), 2)) }
        guard let i = weighted.indices.max(by: { weighted[$0] < weighted[$1] }) else { return nil }
        var lag = Double(lags.lowerBound + i)
        if i > 0, i < weighted.count - 1 {
            let (a, b, c) = (weighted[i - 1], weighted[i], weighted[i + 1])
            let d = a - 2 * b + c
            if d < 0 { lag += 0.5 * (a - c) / d }
        }
        return 60 / (lag * step)
    }

    /// Onsets summed by their phase in the beat: a sharp peak means the beat fits.
    static func fold(_ onsets: [Float], step: Double, bpm: Double) -> (bpm: Double, score: Double, phase: TimeInterval) {
        let bins = 100, period = 60 / bpm
        var histogram = [Double](repeating: 0, count: bins)
        for (m, o) in onsets.enumerated() where o > 0 {
            let phase = (Double(m) * step).truncatingRemainder(dividingBy: period) / period
            histogram[min(Int(phase * Double(bins)), bins - 1)] += Double(o)
        }
        let smooth = histogram.indices.map { histogram[($0 + bins - 1) % bins] + histogram[$0] + histogram[($0 + 1) % bins] }
        let peak = smooth.indices.max { smooth[$0] < smooth[$1] } ?? 0
        return (bpm, smooth[peak], (Double(peak) + 0.5) / Double(bins) * period)
    }

    /// Autocorrelation of the onsets at one beat, 0…1 (pulse clarity): near 0 for noise, near 1 for a click track.
    static func pulse(_ onsets: [Float], lag: Double) -> Double {
        let mean = vDSP.mean(onsets)
        let c = vDSP.add(-mean, onsets), n = c.count
        let energy = Double(vDSP.dot(c, c)) / Double(n)
        let base = Int(lag.rounded())
        guard energy > 0, base > 1, base + 1 < n else { return 0 }
        let r = c.withUnsafeBufferPointer { c in
            (base - 1...base + 1).map { Double(vDSP.dot(UnsafeBufferPointer(rebasing: c[0..<n - $0]), UnsafeBufferPointer(rebasing: c[$0..<n]))) / Double(n - $0) }
        }
        return min(max((r.max() ?? 0) / energy, 0), 1)
    }

    /// Sum of the onsets at frame times `from`, `from + every`, …
    static func accent(_ onsets: [Float], step: Double, from: TimeInterval, every: TimeInterval) -> Float {
        stride(from: from, to: Double(onsets.count) * step, by: every).reduce(0) { sum, t in
            let m = Int((t / step).rounded())
            let near = onsets[max(0, m - 2)..<min(onsets.count, max(0, m + 3))]
            return sum + (near.max() ?? 0)
        }
    }
}
