import Foundation

/// Where a song moves to a new part (intro, verse, chorus…): the times where its sound changes most.
/// Half-second frames get a timbre fingerprint (log band levels and loudness, minus the song's mean); a checkerboard
/// kernel over their self-similarity (Foote novelty) peaks where the frames before differ from the frames after.
enum Sections {
    /// Length of a frame.
    static let frame: TimeInterval = 0.5
    /// Frames each side of a boundary that the kernel compares: 8 s.
    static let half = 16
    /// Least novelty (−1…1) of a boundary. Measured: a steady click song peaks at 0.15; a pop song has its part changes
    /// at 0.21–0.37 and nothing else above 0.10.
    static let threshold: Float = 0.18
    /// Least time between two boundaries, and from the start or end of the sound.
    static let minGap: TimeInterval = 8
    static let margin: TimeInterval = 6
    static let maxCount = 16

    /// Boundary times, sorted; on bar lines when the beat is clear. Empty for short or steady songs.
    static func find(_ samples: [Float], sampleRate: Double, bpm: Double, downbeat: TimeInterval, beatStrength: Double,
                     soundStart: TimeInterval, soundEnd: TimeInterval) -> [TimeInterval] {
        let features = fingerprints(samples, sampleRate: sampleRate)
        let n = features.count
        guard n > 4 * half else { return [] }
        let novelty = Self.novelty(features)
        // Peaks: the highest within ±4 s, strongest first.
        let reach = half / 2
        let peaks = (half..<n - half).filter { i in
            novelty[i] > threshold && (max(half, i - reach)...min(n - half - 1, i + reach)).allSatisfy { novelty[$0] <= novelty[i] }
        }.sorted { novelty[$0] > novelty[$1] }
        var times: [TimeInterval] = []
        let bar = 240 / bpm
        for i in peaks where times.count < maxCount {
            var t = Double(i) * frame
            if beatStrength > 0.3, bpm > 0 { t = downbeat + ((t - downbeat) / bar).rounded() * bar }
            guard t >= soundStart + margin, t <= soundEnd - margin, times.allSatisfy({ abs($0 - t) >= minGap }) else { continue }
            times.append(t)
        }
        return times.sorted()
    }

    /// Per frame: band levels (0…1, as the spectrum shows them) averaged over the frame, and its loudness;
    /// minus the song's mean, scaled to length 1.
    static func fingerprints(_ samples: [Float], sampleRate: Double) -> [[Float]] {
        let hop = Int(sampleRate * frame), window = Spectrum.size, step = window / 2
        let count = samples.count / hop
        guard count > 0, samples.count >= window else { return [] }
        let spectrum = Spectrum()
        var features: [[Float]] = (0..<count).map { f in
            let start = f * hop
            var sum = [Float](repeating: 0, count: 32), windows = 0
            for offset in stride(from: start, through: min(start + hop, samples.count) - window, by: step) {
                let bands = spectrum.bands(Array(samples[offset..<offset + window]), sampleRate: sampleRate, count: 32)
                for b in sum.indices { sum[b] += bands[b] }
                windows += 1
            }
            let end = min(start + hop, samples.count)
            let power = samples[start..<end].reduce(Float(0)) { $0 + $1 * $1 } / Float(max(end - start, 1))
            let loudness = max(0, 1 + 10 * log10(max(power, 1e-12)) / 70)
            return sum.map { $0 / Float(max(windows, 1)) } + [loudness]
        }
        let dims = features[0].count
        let mean = (0..<dims).map { d in features.reduce(Float(0)) { $0 + $1[d] } / Float(count) }
        for f in features.indices {
            var v = zip(features[f], mean).map { $0 - $1 }
            let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            if norm > 1e-6 { v = v.map { $0 / norm } } else { v = v.map { _ in 0 } }
            features[f] = v
        }
        return features
    }

    /// Foote novelty per frame, −1…1: how much the `half` frames before differ from the `half` frames after.
    static func novelty(_ features: [[Float]]) -> [Float] {
        let n = features.count
        var similarity = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in i..<n {
                let s = zip(features[i], features[j]).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                similarity[i * n + j] = s
                similarity[j * n + i] = s
            }
        }
        // Gaussian-tapered checkerboard: + within each side, − across.
        let sigma = Float(half) / 2
        var kernel = [Float](), total: Float = 0
        for a in -half..<half {
            for b in -half..<half {
                let g = exp(-(pow(Float(a) + 0.5, 2) + pow(Float(b) + 0.5, 2)) / (2 * sigma * sigma))
                kernel.append((a < 0) == (b < 0) ? g : -g)
                total += g
            }
        }
        return (0..<n).map { i in
            guard i >= half, i + half <= n else { return 0 }
            var sum: Float = 0, k = 0
            for a in -half..<half {
                let row = (i + a) * n
                for b in -half..<half {
                    sum += kernel[k] * similarity[row + i + b]
                    k += 1
                }
            }
            return sum / total
        }
    }
}
