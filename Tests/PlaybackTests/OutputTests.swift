import AVFoundation
@testable import Playback
import Testing

/// The real playback pipeline, measured on muted decks from what the equalizer tap records: local generated files only.
@MainActor @Suite(.serialized) final class OutputTests {
    private var files: [URL] = []

    deinit { files.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func file(_ mono: [Float]) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("output-\(UUID().uuidString).wav")
        files.append(url)
        try await Task.detached { try OutputCapture.write(mono.flatMap { [$0, $0] }, sampleRate: 44100, to: url) }.value
        return url
    }

    private func item(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral  // as the app plays
        return item
    }

    /// One muted mixer playing a file with the equalizer on.
    private struct Run {
        let mixer: Mixer, recorder: TapRecorder, item: AVPlayerItem

        @MainActor func stop() throws -> OutputCapture.Track {
            mixer.stop()
            return try #require(OutputCapture(mixer: mixer, recorder: recorder).tracks()[ObjectIdentifier(item)])
        }
    }

    private func start(_ url: URL, _ gains: EqualizerGains) -> Run {
        let recorder = TapRecorder()
        let mixer = Mixer(equalizer: Equalizer(recorder: recorder))
        mixer.volume = 0
        mixer.equalizer.set(gains)
        mixer.usesEqualizer = true
        let item = item(url)
        mixer.play(Mixer.Cue(item: item))
        return Run(mixer: mixer, recorder: recorder, item: item)
    }

    private static func band(_ index: Int, _ db: Double) -> EqualizerGains {
        var bands = Array(repeating: 0.0, count: 10)
        bands[index] = db
        return EqualizerGains(preamp: 0, bands: bands)
    }

    private static func preset(_ name: String) -> EqualizerGains {
        EqualizerGains(preamp: 0, bands: EqualizerPreset.builtIn.first { $0.name == name }?.bands ?? [])
    }

    static let presets: [(String, EqualizerGains)] = [("Flat", .flat), ("Bass Booster", preset("Bass Booster")), ("Rock", preset("Rock")), ("+12 dB at 1 kHz", band(5, 12))]

    /// Frames from the start of a tap's run to the first frame of the song, at rate 1: the delay of the time-pitch unit (measured).
    static let delay = 4096

    private func noise(seconds: Double) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 44100)).map { _ in Float.random(in: -0.1...0.1, using: &g) }
    }

    /// A logarithmic sweep from 20 Hz to 20 kHz between half-second silences.
    private func sweep(seconds: Double) -> [Float] {
        let n = Int(seconds * 44100), k = log(1000.0)
        return (0..<n + 44100).map { i in
            let t = Double(i - 22050) / 44100
            guard t >= 0, t < seconds else { return 0 }
            return Float(0.1 * sin(2 * .pi * 20 * seconds / k * (exp(k * t / seconds) - 1)))
        }
    }

    @Test(arguments: ["noise", "sweep"]) func equalizerBandGains(signal: String) async throws {
        let source = signal == "noise" ? noise(seconds: 5) : sweep(seconds: 5)
        let url = try await file(source)
        let seconds = Double(source.count) / 44100 + 0.8
        let runs = Self.presets.map { start(url, $0.1) }
        try await Task.sleep(for: .seconds(seconds))
        for (preset, run) in zip(Self.presets, runs) {
            let track = try run.stop()
            let measured = Measure.bandGains(input: source, output: track.mono(Self.delay..<Self.delay + source.count), sampleRate: 44100)
            let expected = Measure.expectedGains(preset.1, sampleRate: 44100)
            let error = zip(measured, expected).map { abs($0 - $1) }.max() ?? 0
            print("EQ \(signal) \(preset.0): measured \(measured.map { String(format: "%+.2f", $0) }) expected \(expected.map { String(format: "%+.2f", $0) }) worst \(String(format: "%.2f", error)) dB")
            #expect(error < 1, "\(preset.0)")
        }
    }

    /// A steady tone (100 Hz and 1 kHz) while the preset changes three times: the largest sample-to-sample jump
    /// against the jumps around it.
    @Test func presetChangesDoNotClick() async throws {
        let source = (0..<Int(7 * 44100)).map { i in
            let t = Double(i) / 44100
            return Float(0.1 * sin(2 * .pi * 100 * t) + 0.05 * sin(2 * .pi * 1000 * t))
        }
        let url = try await file(source)
        let changes = [(1.5, Self.preset("Rock")), (3, Self.band(5, 12)), (4.5, Self.preset("Bass Booster")), (6, .flat)]
        let run = start(url, .flat)
        var elapsed = 0.0
        for (at, gains) in changes {
            try await Task.sleep(for: .seconds(at - elapsed))
            run.mixer.equalizer.set(gains)
            elapsed = at
        }
        try await Task.sleep(for: .seconds(1.3))
        let track = try run.stop()
        let output = track.mono(Self.delay + 4410..<Self.delay + source.count - 4410)
        let click = Measure.clickRatio(output, sampleRate: 44100)
        let quiet = Measure.clickRatio(Array(source[4410..<source.count - 4410]), sampleRate: 44100)
        // The measure sees a step of a tenth of the signal.
        var stepped = Array(source[4410..<source.count - 4410])
        for i in 44100..<stepped.count { stepped[i] += 0.015 }
        let step = Measure.clickRatio(stepped, sampleRate: 44100)
        print(String(format: "EQ click: worst jump %.2f× the jumps around it at %.2f s (the file itself: %.2f×, with a 0.015 step: %.2f×)",
                     click.ratio, click.at + 0.1, quiet.ratio, step.ratio))
        #expect(step.ratio > 1.5)
        #expect(click.ratio < 1.5)
    }
}
