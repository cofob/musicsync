import Foundation
@testable import MilkDropKit
import Testing

@Suite struct AudioLevelsTests {
    private func sine(_ hz: Double, rate: Double = 44100, amplitude: Float = 0.5) -> [Float] {
        (0..<AudioLevels.sampleCount).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    @Test func startsAtZeroWithAttenuatedOne() {
        let audio = AudioLevels()
        #expect(audio.bass == 0 && audio.mid == 0 && audio.treb == 0)
        #expect(audio.bassAtt == 1 && audio.midAtt == 1 && audio.trebAtt == 1)
    }

    /// As in butterchurn: 0 while the long average fades, 1 once it is gone.
    @Test func silenceIsZeroThenOne() {
        let audio = AudioLevels()
        let silence = [Float](repeating: 0, count: 1024)
        audio.update(left: silence, right: silence, sampleRate: 44100, fps: 60, frame: 0)
        #expect(audio.bass == 0)
        for frame in 1..<1500 { audio.update(left: silence, right: silence, sampleRate: 44100, fps: 60, frame: frame) }
        #expect(audio.bass == 1 && audio.treb == 1)
        #expect(audio.waveLeft.allSatisfy { $0 == 0 })
    }

    @Test func steadyToneSettlesNearOne() {
        let audio = AudioLevels(), tone = sine(100)
        for frame in 0..<600 { audio.update(left: tone, right: tone, sampleRate: 44100, fps: 60, frame: frame) }
        #expect(abs(audio.bass - 1) < 0.05)
        #expect(abs(audio.bassAtt - 1) < 0.05)
    }

    @Test func beatRaisesItsBand() {
        let audio = AudioLevels(), quiet = sine(100, amplitude: 0.05), loud = sine(100, amplitude: 0.8)
        for frame in 0..<300 { audio.update(left: quiet, right: quiet, sampleRate: 48000, fps: 60, frame: frame) }
        audio.update(left: loud, right: loud, sampleRate: 48000, fps: 60, frame: 300)
        #expect(audio.bass > 3)
    }

    @Test func waveformIsInByteScale() {
        let audio = AudioLevels(), full = [Float](repeating: 1, count: 1024)
        audio.update(left: full, right: full.map { -$0 }, sampleRate: 44100, fps: 60, frame: 0)
        #expect(audio.waveLeft[10] == 127)
        #expect(audio.waveRight[10] == -128)
    }
}
