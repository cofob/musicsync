import CoreAudio
import Foundation
@testable import Playback
import Testing

@Suite struct VisualizerTests {
    /// Writes interleaved stereo `samples` into `tap` as one buffer.
    private func write(_ tap: SampleTap, _ samples: [Float], time: TimeInterval, rate: Double = 1000) {
        var data = samples
        data.withUnsafeMutableBufferPointer { p in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(p.count * 4), mData: UnsafeMutableRawPointer(p.baseAddress!)))
            tap.write(UnsafeMutableAudioBufferListPointer(&list), frames: p.count / 2, time: time, sampleRate: rate)
        }
    }

    @Test func sineTopsItsBand() {
        let rate = 44100.0, count = 32
        let sine = (0..<Spectrum.size).map { Float(0.5 * sin(2 * .pi * 1000 * Double($0) / rate)) }
        let bands = Spectrum().bands(sine, sampleRate: rate, count: count)
        let top = bands.indices.max { bands[$0] < bands[$1] }!
        let ratio = Spectrum.range.upperBound / Spectrum.range.lowerBound
        let lo = Spectrum.range.lowerBound * pow(ratio, Double(top) / Double(count))
        let hi = Spectrum.range.lowerBound * pow(ratio, Double(top + 1) / Double(count))
        #expect(lo <= 1030 && hi >= 970)
        #expect(bands[top] > 0.85)  // −6 dB
    }

    @Test func silenceIsZero() {
        #expect(Spectrum().bands([Float](repeating: 0, count: 100), sampleRate: 44100, count: 16).allSatisfy { $0 == 0 })
    }

    @Test func tapKeepsNewestFrames() {
        let tap = SampleTap()
        tap.isOn = true
        write(tap, (0..<10).flatMap { [Float($0), -Float($0)] }, time: 0)
        let (left, right) = tap.latest(4, at: 10)
        #expect(left == [6, 7, 8, 9])
        #expect(right == [-6, -7, -8, -9])
    }

    @Test func tapReadsBehindWhenAhead() {
        let tap = SampleTap()
        tap.isOn = true
        write(tap, (0..<100).flatMap { [Float($0), 0] }, time: 0)  // 0.1 s at 1 kHz
        #expect(tap.latest(3, at: 0.05).left == [47, 48, 49])
    }

    @Test func tapOffWritesNothing() {
        let tap = SampleTap()
        write(tap, [1, 1, 1, 1], time: 0)
        #expect(tap.latest(2, at: 0).left == [0, 0])
    }

    @Test func peaksHoldThenFall() {
        var falloff = Falloff()
        falloff.update([1], dt: 0)
        falloff.update([0], dt: 0.2)
        #expect(falloff.peaks == [1])
        #expect(falloff.bars[0] < 1)
        falloff.update([0], dt: 0.25)
        #expect(falloff.peaks[0] < 1)
        #expect(falloff.bars[0] <= falloff.peaks[0])
    }
}
