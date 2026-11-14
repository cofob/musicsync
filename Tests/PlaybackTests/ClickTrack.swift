import AVFoundation
import Foundation
import Testing

/// A synthetic song with known answers: digital silence, a quiet intro, a loud body and a quiet outro (−12 dB),
/// with a click on every beat (louder on beat one) over a steady tone.
struct ClickTrack {
    var bpm: Double
    var lead = 0.0, intro = 0.0, body = 60.0, outro = 0.0, trail = 0.0
    /// Time of the first click after the lead silence.
    var firstBeat = 0.0
    /// Clicks before the first beat one.
    var pickup = 0

    var period: Double { 60 / bpm }
    var introEnd: Double { lead + intro }
    var outroStart: Double { introEnd + body }
    var soundEnd: Double { outroStart + outro }
    var length: Double { soundEnd + trail }
    var downbeat: Double { lead + firstBeat + Double(pickup) * period }

    func samples(rate: Double = 11025) -> [Float] {
        (0..<Int(length * rate)).map { i in
            let t = Double(i) / rate
            guard t >= lead, t < soundEnd else { return 0 }
            let level = t >= introEnd && t < outroStart ? 1.0 : 0.25
            var x = 0.15 * level * sin(2 * .pi * 220 * t)
            let beat = t - lead - firstBeat
            if beat >= 0 {
                let k = Int(beat / period), dt = beat - Double(k) * period
                let one = (k - pickup) % 4 == 0
                if dt < 0.03 { x += (one ? 0.8 : 0.35) * level * sin(2 * .pi * 1500 * dt) * exp(-dt / 0.006) }
            }
            return Float(x)
        }
    }

    /// A 44.1 kHz stereo WAV in a temp folder.
    func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clicks-\(UUID().uuidString).wav")
        let mono = samples(rate: 44100)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count)))
        buffer.frameLength = AVAudioFrameCount(mono.count)
        for channel in 0..<2 { mono.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: mono.count) } }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }
}
