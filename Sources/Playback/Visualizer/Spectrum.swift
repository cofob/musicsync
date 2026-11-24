import Accelerate
import Foundation

/// Levels of log-spaced frequency bands, 0…1 from −70 dB to 0 dB full scale, as old player spectrum bars show them.
public struct Spectrum {
    public static let size = 2048
    public static let floor: Float = -70
    public static let range: ClosedRange<Double> = 40...16000

    private let dft = try? vDSP.DiscreteFourierTransform(count: Spectrum.size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Spectrum.size, isHalfWindow: false)
    private let zeros = [Float](repeating: 0, count: Spectrum.size)

    public init() {}

    /// `count` band levels of the last `size` samples (fewer are padded with silence).
    public func bands(_ samples: [Float], sampleRate: Double, count: Int) -> [Float] {
        guard let dft, count > 0, sampleRate > 0 else { return [] }
        let n = Self.size
        let input = Array(samples.suffix(n)) + [Float](repeating: 0, count: max(n - samples.count, 0))
        let (re, im) = dft.transform(real: vDSP.multiply(input, window), imaginary: zeros)
        // A full-scale sine peaks at n / 4 after the Hann window.
        let scale = 4 / Float(n)
        let magnitude = (0..<n / 2).map { scale * (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() }
        let ratio = Self.range.upperBound / Self.range.lowerBound
        let binWidth = sampleRate / Double(n)
        return (0..<count).map { band in
            let lo = Self.range.lowerBound * pow(ratio, Double(band) / Double(count))
            let hi = Self.range.lowerBound * pow(ratio, Double(band + 1) / Double(count))
            let first = min(Int((lo / binWidth).rounded()), n / 2 - 1)
            let last = min(max(Int((hi / binWidth).rounded()), first + 1), n / 2)
            let peak = magnitude[first..<last].max() ?? 0
            let db = 20 * log10(max(peak, 1e-9))
            return min(max((db - Self.floor) / -Self.floor, 0), 1)
        }
    }
}

/// Bars that jump up and fall slowly, with peak caps that hold, then fall: the Winamp look.
public struct Falloff {
    /// Levels per second.
    public var barFall: Float = 1.6
    public var peakFall: Float = 0.6
    public var peakHold: TimeInterval = 0.4
    /// Levels per second a bar may rise; the default rises at once.
    public var barRise: Float = .greatestFiniteMagnitude
    public private(set) var bars: [Float] = []
    public private(set) var peaks: [Float] = []
    private var held: [TimeInterval] = []

    public init() {}

    public mutating func update(_ levels: [Float], dt: TimeInterval) {
        if bars.count != levels.count { bars = levels; peaks = levels; held = levels.map { _ in 0 }; return }
        let dt = Float(min(max(dt, 0), 0.25))
        for i in levels.indices {
            bars[i] = min(max(levels[i], bars[i] - barFall * dt), bars[i] + barRise * dt)
            if bars[i] >= peaks[i] { peaks[i] = bars[i]; held[i] = 0 }
            else {
                held[i] += Double(dt)
                if held[i] > peakHold { peaks[i] = max(bars[i], peaks[i] - peakFall * dt) }
            }
        }
    }
}
