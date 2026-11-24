import Foundation
import Support

/// Mood of a song or of one of its parts, from measures that can be explained (all 0…1 after scaling):
///
/// - arousal = 0.4 loudness (−40…−10 dB) + 0.3 onset density (0.5…6 a second) + 0.3 tempo (70…180 bpm).
///   Tempo counts as much as the beat is clear: with a weak beat it is 0.5.
/// - valence = 0.55 mode (how much better the pitch classes fit a major key than a minor one) + 0.45 brightness
///   (spectral centroid, 400…3200 Hz on a log scale).
/// - tension = 0.6 dissonance (pitch classes a semitone or a tritone apart sounding together) + 0.4 dynamics
///   (how much the loudness varies, 0…8 dB).
struct MoodMeter {
    let frames: MoodFrames
    let onsets: [Float]
    let onsetStep: TimeInterval
    let bpm: Double
    let beatStrength: Double

    /// Weights of intervals between two pitch classes (by their distance, 0…6 semitones) in the dissonance.
    static let roughness: [Double] = [0, 1, 0.3, 0, 0, 0, 0.6]
    /// Krumhansl-Kessler key profiles, from the tonic up.
    static let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// The mood between two times; nil without sound there.
    func mood(from start: TimeInterval, to end: TimeInterval) -> Mood? {
        let used = frames.sounding(start, end)
        guard !used.isEmpty else { return nil }
        let db = used.map { frames.db[$0] }
        let power = db.map { pow(10, $0 / 10) }.reduce(0, +) / Double(used.count)
        let loudness = Mood.scaled(10 * log10(power), -40, -10)
        let seconds = max(end - start, frames.step)
        let density = Mood.scaled(Double(onsetCount(start, end)) / seconds, 0.5, 6)
        let clear = min(beatStrength / 0.3, 1)
        let tempo = 0.5 + (Mood.scaled(bpm, 70, 180) - 0.5) * clear

        var chroma = [Double](repeating: 0, count: 12)
        for f in used { for p in 0..<12 { chroma[p] += frames.chroma[f][p] / Double(used.count) } }
        let mode = Mood.scaled(Self.majorness(chroma), -0.3, 0.3)
        let centroid = used.map { log2(max(frames.centroid[$0], 1)) }.reduce(0, +) / Double(used.count)
        let brightness = Mood.scaled(centroid, log2(400), log2(3200))

        let mean = db.reduce(0, +) / Double(db.count)
        let spread = (db.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(db.count)).squareRoot()
        return Mood(arousal: 0.4 * loudness + 0.3 * density + 0.3 * tempo,
                    valence: 0.55 * mode + 0.45 * brightness,
                    tension: 0.6 * Mood.scaled(Self.dissonance(chroma), 0.05, 0.3) + 0.4 * Mood.scaled(spread, 0, 8))
    }

    /// Onsets in `start..<end`: peaks of the onset strength above 1.5 times its mean, 46 ms apart at least.
    func onsetCount(_ start: TimeInterval, _ end: TimeInterval) -> Int {
        guard !onsets.isEmpty else { return 0 }
        let bar = 1.5 * onsets.reduce(0, +) / Float(onsets.count)
        let lo = max(Int(start / onsetStep), 0), hi = min(Int(end / onsetStep), onsets.count)
        guard lo + 4 < hi - 4 else { return 0 }
        return (lo + 4..<hi - 4).filter { m in onsets[m] > bar && onsets[m - 4...m + 4].allSatisfy { $0 <= onsets[m] } }.count
    }

    /// Correlation of the pitch classes with the best major key, minus that with the best minor key: −1…1.
    static func majorness(_ chroma: [Double]) -> Double {
        func best(_ profile: [Double]) -> Double {
            (0..<12).map { tonic in correlation(chroma, (0..<12).map { profile[($0 - tonic + 12) % 12] }) }.max() ?? 0
        }
        return best(major) - best(minor)
    }

    /// Roughness of the pitch classes: the weighted share of note pairs a semitone, a whole tone or a tritone apart.
    static func dissonance(_ chroma: [Double]) -> Double {
        var rough = 0.0, all = 0.0
        for i in 0..<12 {
            for j in i + 1..<12 {
                let distance = min(j - i, 12 - (j - i)), pair = chroma[i] * chroma[j]
                rough += pair * roughness[distance]
                all += pair
            }
        }
        return all > 0 ? rough / all : 0
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let (ma, mb) = (a.reduce(0, +) / Double(a.count), b.reduce(0, +) / Double(b.count))
        let (da, db) = (a.map { $0 - ma }, b.map { $0 - mb })
        let norm = (da.map { $0 * $0 }.reduce(0, +) * db.map { $0 * $0 }.reduce(0, +)).squareRoot()
        return norm > 0 ? zip(da, db).map { $0 * $1 }.reduce(0, +) / norm : 0
    }
}
