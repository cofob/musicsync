import CoreAudio
import Foundation

/// Preamp and band gains in dB, clamped to ±12. The filters play these.
public struct EqualizerGains: Equatable, Sendable {
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let range = -12.0...12.0
    public static let flat = EqualizerGains(preamp: 0, bands: [])

    public private(set) var preamp: Double
    public private(set) var bands: [Double]

    public init(preamp: Double, bands: [Double]) {
        self.preamp = Self.clamp(preamp)
        self.bands = Self.fit(bands)
    }

    /// Ten values in range; a missing or broken value is 0.
    static func fit(_ bands: [Double]) -> [Double] {
        frequencies.indices.map { bands.indices.contains($0) ? clamp(bands[$0]) : 0 }
    }

    private static func clamp(_ db: Double) -> Double { db.isFinite ? min(max(db, range.lowerBound), range.upperBound) : 0 }
}

/// RBJ cookbook peaking filter, divided by a0.
struct Biquad: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static func peaking(frequency: Double, gain: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40), w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q), cosw = cos(w), a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0, a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }
}

/// The equalizer DSP for one audio stream: preamp, then ten peaking filters in series, then a clamp to ±1.
/// Gain changes ramp over short blocks, so a slider move does not click. Flat gains leave the samples untouched.
/// Not thread-safe: one audio thread calls `set` and `process`.
public final class EqualizerProcessor {
    /// One octave per band.
    static let q = 1.41
    /// Frames per gain step.
    static let block = 32
    /// Fastest gain change, dB per second.
    static let ramp = 120.0
    /// Filter state below this is set to 0, so silence does not run into denormals.
    static let floor = 1e-30

    public let sampleRate: Double
    public let channels: Int
    private var target: [Double]
    /// Preamp and bands as they play now, moving to `target`.
    private var gains: [Double]
    private var filters: [Biquad]
    /// x1, x2, y1, y2 per channel and band.
    private var state: [Double]
    /// Bands at or above this index are too close to Nyquist and stay off.
    private let bandCount: Int

    public init(sampleRate: Double, channels: Int, gains: EqualizerGains = .flat) {
        self.sampleRate = sampleRate
        self.channels = max(channels, 0)
        let values = [gains.preamp] + gains.bands
        target = values
        self.gains = values
        bandCount = EqualizerGains.frequencies.firstIndex { $0 >= 0.45 * sampleRate } ?? EqualizerGains.frequencies.count
        filters = Array(repeating: Biquad(), count: EqualizerGains.frequencies.count)
        state = Array(repeating: 0, count: self.channels * EqualizerGains.frequencies.count * 4)
        for band in 0..<bandCount { filters[band] = filter(band) }
    }

    /// New target gains; copied in place, so the audio thread does not allocate.
    public func set(_ gains: EqualizerGains) {
        target[0] = gains.preamp
        for (i, db) in gains.bands.enumerated() { target[i + 1] = db }
    }

    /// Filters `frames` frames of 32-bit float samples in place, interleaved or not. Channels past `channels` stay as they are.
    public func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var start = 0
        while start < frames {
            let count = min(Self.block, frames - start)
            let preFrom = gains[0]
            step(count)
            if !isFlat { filter(buffers, from: start, count: count, preFrom: pow(10, preFrom / 20), preTo: pow(10, gains[0] / 20)) }
            start += count
        }
    }

    /// No filter and no preamp: nothing to do.
    private var isFlat: Bool { gains.allSatisfy { $0 == 0 } }

    /// Moves the gains one block toward the target and rebuilds the filters that changed.
    private func step(_ count: Int) {
        let limit = Self.ramp * Double(count) / sampleRate
        for i in gains.indices where gains[i] != target[i] {
            let delta = target[i] - gains[i]
            gains[i] = abs(delta) <= limit ? target[i] : gains[i] + (delta > 0 ? limit : -limit)
            guard i > 0, i - 1 < bandCount else { continue }
            filters[i - 1] = filter(i - 1)
            if gains[i] == 0 { clearState(band: i - 1) }
        }
    }

    private func filter(_ band: Int) -> Biquad {
        Biquad.peaking(frequency: EqualizerGains.frequencies[band], gain: gains[band + 1], q: Self.q, sampleRate: sampleRate)
    }

    private func filter(_ buffers: UnsafeMutableAudioBufferListPointer, from start: Int, count: Int, preFrom: Double, preTo: Double) {
        var channel = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            for offset in 0..<stride where channel < channels {
                filterChannel(channel, data + offset, stride: stride, from: start, count: count, preFrom: preFrom, preTo: preTo)
                channel += 1
            }
        }
    }

    private func filterChannel(_ channel: Int, _ data: UnsafeMutablePointer<Float>, stride: Int, from start: Int, count: Int,
                               preFrom: Double, preTo: Double) {
        let base = channel * EqualizerGains.frequencies.count * 4
        for frame in 0..<count {
            let index = (start + frame) * stride
            var x = Double(data[index]) * (preFrom + (preTo - preFrom) * Double(frame + 1) / Double(count))
            for band in 0..<bandCount where gains[band + 1] != 0 {
                let f = filters[band], s = base + band * 4
                let y = f.b0 * x + f.b1 * state[s] + f.b2 * state[s + 1] - f.a1 * state[s + 2] - f.a2 * state[s + 3]
                state[s + 1] = state[s]
                state[s] = x
                state[s + 3] = state[s + 2]
                state[s + 2] = y
                x = y
            }
            data[index] = Float(min(max(x, -1), 1))
        }
        for i in base..<base + EqualizerGains.frequencies.count * 4 where !(abs(state[i]) >= Self.floor) { state[i] = 0 }  // also NaN
    }

    private func clearState(band: Int) {
        for channel in 0..<channels {
            let s = (channel * EqualizerGains.frequencies.count + band) * 4
            for i in s..<s + 4 { state[i] = 0 }
        }
    }
}
