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

    /// Two songs of one album in one deck with the equalizer on: the second starts where the first ends, on the
    /// clock (item timebases) and in the sound (a steady tone runs on across the change).
    @Test func gaplessWithEqualizer() async throws {
        let a = ClickTrack(bpm: 120, body: 3, firstBeat: 0.1), b = ClickTrack(bpm: 120, body: 3, firstBeat: 0.1)
        let recorder = TapRecorder()
        let mixer = Mixer(equalizer: Equalizer(recorder: recorder))
        mixer.volume = 0
        mixer.equalizer.set(Self.preset("Rock"))
        mixer.usesEqualizer = true
        let ia = item(try await a.file()), ib = item(try await b.file())
        files += [ia, ib].compactMap { ($0.asset as? AVURLAsset)?.url }
        let capture = OutputCapture(mixer: mixer, recorder: recorder)
        capture.start()
        mixer.play(Mixer.Cue(item: ia))
        mixer.setNext(Mixer.Cue(item: ib))
        try await Task.sleep(for: .seconds(5))
        capture.stop()
        mixer.stop()
        // On the clock: where a reaches its end and b its start.
        let end = try #require(capture.host(of: ia, at: a.length)), begin = try #require(capture.host(of: ib, at: 0))
        let clockGap = (begin - end) * 1000
        // In the sound: both recordings lined up by their clicks, then rendered.
        var tracks = capture.tracks()
        let idA = ObjectIdentifier(ia), idB = ObjectIdentifier(ib)
        let source = a.samples(rate: 44100)
        let trackA = try #require(tracks[idA]), trackB = try #require(tracks[idB])
        tracks[idA]?.anchor = capture.anchor(trackA, of: idA, source: source, sourceRate: 44100, from: end - 2.5)?.anchor
        tracks[idB]?.anchor = capture.anchor(trackB, of: idB, source: source, sourceRate: 44100, from: begin + 0.05)?.anchor
        let render = capture.render(tracks, from: end - 0.3, to: end + 0.3)
        let silence = Measure.longestSilence(render.mix, sampleRate: 44100, threshold: -40) * 1000
        // Both songs heard at once: frames where both decks have sound.
        let overlap = Double((0..<render.frames).count { abs(render.decks[0][2 * $0]) > 1e-3 && abs(render.decks[1][2 * $0]) > 1e-3 }) / 44.1
        let mono = Measure.mono(render.mix)
        let jumps = zip(mono.dropFirst(), mono).map { abs($0 - $1) }
        let mid = jumps.count / 2, joint = jumps[mid - 441..<mid + 441].max() ?? 0, typical = jumps.sorted()[jumps.count * 99 / 100]
        let lastA = tracks[idA]?.anchor.map { $0 + Double(trackA.frames) / 44100 - end } ?? .nan
        print(String(format: "EQ gapless: clock gap %+.2f ms, silence %.0f ms, overlap %.1f ms, joint jump %.4f vs normal %.4f, a's recording ends %+.1f ms after its end",
                     clockGap, silence, overlap, joint, typical, lastA * 1000))
        #expect(abs(clockGap) < 5)
        #expect(silence < 5)
        #expect(overlap < 5)
    }

    private func song(_ track: ClickTrack) async throws -> MixRun.Song {
        let url = try await track.file()
        files.append(url)
        return MixRun.Song(cue: Mixer.Cue(item: item(url)), source: track.samples(rate: 44100))
    }

    /// AutoMix of two click tracks on the real mixer, as heard: beat-matched (120 into 123 bpm) and faded (into 95 bpm).
    @Test(arguments: [123.0, 95]) func autoMixOutput(bpm: Double) async throws {
        let ta = ClickTrack(bpm: 120, lead: 0.5, body: 40, trail: 0.5, firstBeat: 0.1)
        let tb = ClickTrack(bpm: bpm, lead: 0.7, body: 40, trail: 0.5, firstBeat: 0.23, pickup: 1, tone: 330)
        let aa = SongAnalysis(samples: ta.samples()), ab = SongAnalysis(samples: tb.samples())
        let t = try #require(AutoMix.plan(from: aa, to: ab))
        let matched = AutoMix.tempoMatch(aa, ab) != nil
        #expect(matched == (bpm == 123))
        let run = MixRun(a: try await song(ta), b: try await song(tb), transition: t, bpm: matched ? aa.bpm : nil)
        let r = try await run.run(wav: "automix-clicks-\(Int(bpm))")
        print("MIX clicks 120 → \(Int(bpm)) bpm, \(String(format: "%.1f", t.duration)) s, rate \(t.rate): \(r.summary)")
        #expect(r.beatOffsets.allSatisfy { abs($0) < 10 })
        #expect(r.dip < 3 && r.jump < 3)
        #expect(r.silence < 0.05)
        #expect(r.peak <= 1)
        #expect(r.rateStep < 0.001)
    }
}
