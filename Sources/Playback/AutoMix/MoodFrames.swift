import Accelerate
import Foundation

/// Short-time facts of a song that its mood is made from, per frame of 4096 samples (0.37 s at 11 kHz):
/// loudness, brightness and which pitch classes sound.
struct MoodFrames {
    static let size = 4096
    /// A frame quieter than this (dB full scale) is silence and counts for nothing.
    static let silence = -60.0

    let step: TimeInterval
    /// Mean power in dB full scale.
    let db: [Double]
    /// Spectral centroid in Hz: where the sound's weight is.
    let centroid: [Double]
    /// Strength of the 12 pitch classes (C = 0) from 100 to 2000 Hz, scaled to sum 1.
    let chroma: [[Double]]

    init(_ samples: [Float], sampleRate: Double) {
        let n = Self.size, count = samples.count / n
        step = Double(n) / sampleRate
        guard count > 0, let dft = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self) else {
            (db, centroid, chroma) = ([], [], [])
            return
        }
        let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: n)
        let width = sampleRate / Double(n)
        var (db, centroid, chroma) = ([Double](), [Double](), [[Double]]())
        for f in 0..<count {
            let frame = Array(samples[f * n..<(f + 1) * n])
            db.append(10 * log10(max(Double(vDSP.meanSquare(frame)), 1e-12)))
            let (re, im) = dft.transform(inputReal: vDSP.multiply(frame, hann), inputImaginary: zeros)
            var weight = 0.0, total = 0.0, pitch = [Double](repeating: 0, count: 12)
            for k in 1..<n / 2 {
                let magnitude = Double((re[k] * re[k] + im[k] * im[k]).squareRoot()), hz = Double(k) * width
                weight += hz * magnitude
                total += magnitude
                if (100...2000).contains(hz) { pitch[Self.pitchClass(hz)] += magnitude }
            }
            let sum = pitch.reduce(0, +)
            centroid.append(total > 0 ? weight / total : 0)
            chroma.append(sum > 0 ? pitch.map { $0 / sum } : pitch)
        }
        (self.db, self.centroid, self.chroma) = (db, centroid, chroma)
    }

    /// 0…11 for C…B, of the nearest note.
    static func pitchClass(_ hz: Double) -> Int {
        let note = Int((12 * log2(hz / 440) + 69).rounded())
        return (note % 12 + 12) % 12
    }

    /// The frames that start in `start..<end` and are not silent.
    func sounding(_ start: TimeInterval, _ end: TimeInterval) -> [Int] {
        db.indices.filter { start <= Double($0) * step && Double($0) * step < end && db[$0] > Self.silence }
    }
}
