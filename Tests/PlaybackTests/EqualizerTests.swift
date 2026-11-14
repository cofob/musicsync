import CoreAudio
import Foundation
@testable import Playback
import Testing

@Suite struct EqualizerTests {
    /// Runs `samples` (mono, or interleaved with `channels`) through `processor` in blocks of `block` frames.
    private func run(_ processor: EqualizerProcessor, _ samples: [Float], channels: Int = 1, block: Int = 512) -> [Float] {
        var out = samples
        let frames = samples.count / channels
        out.withUnsafeMutableBufferPointer { data in
            var start = 0
            while start < frames {
                let n = min(block, frames - start)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(n * channels * 4),
                    mData: UnsafeMutableRawPointer(data.baseAddress! + start * channels)))
                processor.process(UnsafeMutableAudioBufferListPointer(&list), frames: n)
                start += n
            }
        }
        return out
    }

    private func sine(_ frequency: Double, rate: Double, seconds: Double = 1, amplitude: Double = 0.05) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// Level change in dB over the second half, after the filters settled.
    private func gain(_ input: [Float], _ output: [Float]) -> Double {
        func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count)) }
        let half = input.count / 2
        return 20 * log10(rms(output[half...]) / rms(input[half...]))
    }

    private func boost(_ band: Int, _ db: Double = 12) -> EqualizerGains {
        var bands = Array(repeating: 0.0, count: 10)
        bands[band] = db
        return EqualizerGains(preamp: 0, bands: bands)
    }

    private func noise(_ count: Int, amplitude: Float = 0.5) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &g) }
    }

    @Test func flatIsBitTransparent() {
        let input = noise(44100 * 2, amplitude: 1.2)
        let processor = EqualizerProcessor(sampleRate: 44100, channels: 2, gains: EqualizerPreset.flat.gains)
        #expect(run(processor, input, channels: 2) == input)
        // Off after a boost: once the ramp is back at 0 the samples pass untouched again.
        let ramped = EqualizerProcessor(sampleRate: 44100, channels: 2, gains: boost(5))
        _ = run(ramped, noise(4410 * 2), channels: 2)
        ramped.set(.flat)
        _ = run(ramped, noise(4410 * 2), channels: 2)
        #expect(run(ramped, input, channels: 2) == input)
    }

    @Test func bandBoostsItsCenterOnly() {
        let rate = 44100.0
        let processor = { EqualizerProcessor(sampleRate: rate, channels: 1, gains: boost(5)) }
        let center = sine(1000, rate: rate)
        let db = gain(center, run(processor(), center))
        #expect(abs(db - 12) < 0.3)
        for far in [32.0, 64, 8000, 16000] {
            let input = sine(far, rate: rate, seconds: 2)
            let db = gain(input, run(processor(), input))
            #expect(abs(db) < 0.5)
        }
    }

    @Test func preampAndClamp() {
        let input = sine(1000, rate: 48000)
        let up = run(EqualizerProcessor(sampleRate: 48000, channels: 1, gains: EqualizerGains(preamp: -6, bands: [])), input)
        #expect(abs(gain(input, up) + 6) < 0.05)
        let loud = run(EqualizerProcessor(sampleRate: 48000, channels: 1, gains: EqualizerGains(preamp: 12, bands: boost(0).bands)), noise(48000, amplitude: 1))
        #expect(loud.allSatisfy { abs($0) <= 1 })
    }

    @Test func sampleRates() {
        for rate in [8000.0, 22050, 32000, 44100, 48000, 88200, 96000, 192000] {
            let processor = EqualizerProcessor(sampleRate: rate, channels: 2, gains: EqualizerGains(preamp: 0, bands: Array(repeating: 12, count: 10)))
            let input = sine(250, rate: rate, seconds: 2).flatMap { [$0, $0] }
            let out = run(processor, input, channels: 2)
            #expect(out.allSatisfy { $0.isFinite })
            let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
            let db = gain(sine(250, rate: rate, seconds: 2), left)
            #expect(db > 12 && db < 24)
        }
    }

    @Test func changesStayFiniteAndSmooth() {
        let processor = EqualizerProcessor(sampleRate: 44100, channels: 1)
        let input = sine(1000, rate: 44100, seconds: 0.1)
        processor.set(boost(5))
        let first = run(processor, input, block: 32)
        // The first block is almost unchanged: the gain ramps.
        #expect(zip(first.prefix(32), input).allSatisfy { abs($0 - $1) < 0.002 })
        var out: [Float] = []
        for i in 0..<200 {
            processor.set(EqualizerGains(preamp: i % 2 == 0 ? 12 : -12, bands: Array(repeating: i % 3 == 0 ? 12 : -12, count: 10)))
            out += run(processor, noise(256, amplitude: 1), block: 64)
        }
        #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
        // Silence after loud input decays to exact zeros, not denormals.
        let tail = run(processor, Array(repeating: 0, count: 44100 * 3))
        #expect(tail.allSatisfy { $0 == 0 || abs($0) >= .leastNormalMagnitude })
        #expect(tail.suffix(1000).allSatisfy { $0 == 0 })
        // NaN input does not stick in the filters.
        _ = run(processor, [.nan] + Array(repeating: 0.1, count: 99))
        #expect(run(processor, noise(4410)).allSatisfy { $0.isFinite })
    }

    @Test func presets() {
        let names = EqualizerPreset.builtIn.map(\.name)
        #expect(names == ["Acoustic", "Bass Booster", "Bass Reducer", "Classical", "Dance", "Deep", "Electronic", "Flat", "Hip-Hop", "Jazz",
                          "Late Night", "Latin", "Loudness", "Lounge", "Piano", "Pop", "R&B", "Rock", "Small Speakers", "Spoken Word",
                          "Treble Booster", "Treble Reducer", "Vocal Booster"])
        #expect(EqualizerPreset.builtIn.allSatisfy { $0.bands.count == 10 && $0.bands.allSatisfy(EqualizerGains.range.contains) })
        #expect(EqualizerPreset.flat.bands.allSatisfy { $0 == 0 })
        #expect(EqualizerPreset.builtIn.first { $0.name == "Bass Booster" }?.bands.prefix(2) == [5.5, 4.25])
    }

    @Test func settingsEditing() {
        var s = EqualizerSettings()
        #expect(s.gains == .flat)
        s.isOn = true
        s.apply(EqualizerPreset.builtIn[17])
        #expect(s.preset == "Rock")
        #expect(s.gains.bands == EqualizerPreset.builtIn[17].bands)
        s.setBand(0, to: 20)
        #expect(s.preset == nil)
        #expect(s.gains.bands[0] == 12)
        #expect(!s.canSave(as: "Rock") && !s.canSave(as: "  "))
        s.savePreset(as: " Mine ")
        s.savePreset(as: "Mine")
        #expect(s.userPresets.map(\.name) == ["Mine"])
        #expect(s.preset == "Mine" && s.presets.count == 24)
        s.deletePreset("Mine")
        #expect(s.userPresets.isEmpty && s.preset == nil)
    }

    @Test func settingsDecode() throws {
        let defaults = try #require(UserDefaults(suiteName: "eq-test-\(UUID().uuidString)"))
        #expect(EqualizerSettings.load(from: defaults) == EqualizerSettings())
        var s = EqualizerSettings()
        s.isOn = true
        s.preamp = -3
        s.apply(EqualizerPreset.builtIn[0])
        s.savePreset(as: "Mine")
        s.save(to: defaults)
        #expect(EqualizerSettings.load(from: defaults) == s)

        let empty = try JSONDecoder().decode(EqualizerSettings.self, from: Data("{}".utf8))
        #expect(empty == EqualizerSettings())
        let short = try JSONDecoder().decode(EqualizerSettings.self, from: Data(#"{"isOn":true,"bands":[3,4],"userPresets":[{"name":"A","bands":[1]}]}"#.utf8))
        #expect(short.isOn && short.preamp == 0 && short.preset == nil)
        #expect(short.bands == [3, 4, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(short.userPresets.first?.bands.count == 10)
    }
}

private extension EqualizerPreset {
    var gains: EqualizerGains { EqualizerGains(preamp: 0, bands: bands) }
}
