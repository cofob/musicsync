import Accelerate
import Foundation

/// Loudness of a song in frames of about 50 ms, raw and smoothed over 0.5 s, in dB full scale.
struct Loudness {
    /// A level must hold this long to count as the song's stable level.
    static let stable: TimeInterval = 2
    let raw: [Double]
    let smooth: [Double]
    /// Length of a frame: a whole number of samples.
    let frame: TimeInterval

    init(_ samples: [Float], sampleRate: Double) {
        let n = max(Int(sampleRate * 0.05), 1)
        frame = Double(n) / sampleRate
        let power: [Double] = samples.withUnsafeBufferPointer { s in
            (0..<samples.count / n).map { Double(vDSP.meanSquare(UnsafeBufferPointer(rebasing: s[$0 * n..<($0 + 1) * n]))) }
        }
        var sums = [0.0]
        for p in power { sums.append(sums[sums.count - 1] + p) }
        let half = Int(0.25 / frame)
        raw = power.map(Self.dB)
        smooth = power.indices.map { i in
            let lo = max(0, i - half), hi = min(power.count, i + half)
            return Self.dB((sums[hi] - sums[lo]) / Double(hi - lo))
        }
    }

    static func dB(_ power: Double) -> Double { 10 * log10(max(power, 1e-12)) }

    /// Silence at both ends, and where the energy reaches and leaves the level of the song's body
    /// (its median, minus 3 dB) for at least `stable` seconds.
    func shape() -> (soundStart: TimeInterval, soundEnd: TimeInterval, introEnd: TimeInterval, outroStart: TimeInterval) {
        let length = Double(raw.count) * frame
        guard let first = raw.firstIndex(where: { $0 > -70 }), let last = raw.lastIndex(where: { $0 > -70 }) else {
            return (0, length, 0, length)
        }
        let body = smooth[first...last].sorted()[(last - first) / 2]
        let quiet = max(-70, body - 30)
        let start = raw.firstIndex { $0 > quiet } ?? first, end = raw.lastIndex { $0 > quiet } ?? last
        let loud = body - 3, hold = Int(Self.stable / frame)
        let intro = (start...end).first { i in smooth[i..<min(i + hold, end + 1)].allSatisfy { $0 >= loud } } ?? start
        let outro = (start...end).reversed().first { j in smooth[max(j - hold + 1, start)...j].allSatisfy { $0 >= loud } } ?? end
        let time = { (i: Int) in Double(i) * frame }
        return (time(start), time(end + 1), time(intro), max(time(outro + 1), time(intro)))
    }
}
