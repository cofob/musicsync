import Accelerate
import Foundation

/// What presets get from the music each frame, as butterchurn computes it from 1024 samples per channel:
/// waveforms, spectra and the bass/mid/treb levels (about 1 on average, higher on beats).
public final class AudioLevels {
    public static let sampleCount = 1024
    /// Waveforms of 512 points, smoothed pairs of samples, in the −128…127 scale of 8-bit audio.
    public private(set) var waveLeft = [Float](repeating: 0, count: 512), waveRight = [Float](repeating: 0, count: 512)
    /// 512 equalized frequency magnitudes: of the mono mix, and of each channel.
    public private(set) var spectrum = [Float](repeating: 0, count: 512)
    public private(set) var spectrumLeft = [Float](repeating: 0, count: 512), spectrumRight = [Float](repeating: 0, count: 512)
    /// Before the first `update`: 0, the attenuated ones 1, as butterchurn starts (the first preset's init sees these).
    public private(set) var bass: Float = 0, mid: Float = 0, treb: Float = 0
    public private(set) var bassAtt: Float = 1, midAtt: Float = 1, trebAtt: Float = 1

    private let dft = vDSP.DFT(count: sampleCount, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    private let equalize = (0..<512).map { Float(-0.02 * log(Double(512 - $0) / 512)) }
    private let zeros = [Float](repeating: 0, count: sampleCount)
    private var avg: [Float] = [1, 1, 1], longAvg: [Float] = [1, 1, 1]

    public init() {}

    /// `left` and `right` are float samples (−1…1) of the frames that play now; fewer than 1024 are padded with silence.
    public func update(left: [Float], right: [Float], sampleRate: Double, fps: Double, frame: Int) {
        let l = Self.bytes(left), r = Self.bytes(right)
        let mono = Self.bytes(zip(left, right).map { ($0 + $1) / 2 })
        var previous = 0
        for i in stride(from: 0, to: Self.sampleCount, by: 2) {
            waveLeft[i / 2] = (0.5 * (l[i] + l[previous])).rounded(.towardZero)
            waveRight[i / 2] = (0.5 * (r[i] + r[previous])).rounded(.towardZero)
            previous = i + 1
        }
        spectrum = magnitudes(mono)
        spectrumLeft = magnitudes(l)
        spectrumRight = magnitudes(r)
        levels(sampleRate: sampleRate, fps: fps, frame: frame)
    }

    /// Samples as butterchurn's signed bytes: `getByteTimeDomainData` − 128.
    private static func bytes(_ samples: [Float]) -> [Float] {
        let padded = Array(samples.suffix(sampleCount)) + [Float](repeating: 0, count: max(sampleCount - samples.count, 0))
        return padded.map { (min(max(1 + $0, 0), 2) * 128).rounded(.down).clamped(0, 255) - 128 }
    }

    private func magnitudes(_ samples: [Float]) -> [Float] {
        guard let dft else { return [Float](repeating: 0, count: 512) }
        let (re, im) = dft.transform(inputReal: samples, inputImaginary: zeros)
        return (0..<512).map { equalize[$0] * (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() }
    }

    private func levels(sampleRate: Double, fps: Double, frame: Int) {
        let binWidth = sampleRate / Double(Self.sampleCount)
        let bin = { (hz: Double) in min(max(Int((hz / binWidth).rounded()) - 1, 0), 511) }
        let edges = [bin(20), bin(320), bin(2800), bin(11025)]
        let fps = fps.isFinite ? min(max(fps, 15), 144) : 15
        let adjust = { (rate: Float) in Float(pow(Double(rate), 30 / fps)) }
        var val: [Float] = [1, 1, 1], att: [Float] = [1, 1, 1]
        for band in 0..<3 {
            let imm = spectrum[edges[band]..<max(edges[band + 1], edges[band])].reduce(0, +)
            var rate = adjust(imm > avg[band] ? 0.2 : 0.5)
            avg[band] = avg[band] * rate + imm * (1 - rate)
            rate = adjust(frame < 50 ? 0.9 : 0.992)
            longAvg[band] = longAvg[band] * rate + imm * (1 - rate)
            if longAvg[band] >= 0.001 {
                val[band] = imm / longAvg[band]
                att[band] = avg[band] / longAvg[band]
            }
        }
        (bass, mid, treb) = (val[0], val[1], val[2])
        (bassAtt, midAtt, trebAtt) = (att[0], att[1], att[2])
    }
}

extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(self, lo), hi) }
}
