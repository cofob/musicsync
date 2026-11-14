import Accelerate
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
        item.audioTimePitchAlgorithm = .timeDomain  // as the app plays
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

    /// Waits until the mixers have played to the end, at most `timeout` seconds: a busy machine can start a deck late.
    private func ended(_ mixers: [Mixer], timeout: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while mixers.contains(where: \.hasCurrent), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
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

    /// Frames from the start of a tap's run to the first frame of the song, at rate 1: the delay of the time-pitch unit,
    /// about 1024 (measured). It varies a little, so a band measure lines the frames up exactly.
    static let delay = 1024

    /// The first frame of `source` in the mono recording of `track`, within 8192 frames of `delay`: where the 4096
    /// frames from `mid` match best.
    private static func start(of source: [Float], at mid: Int, in track: OutputCapture.Track) -> Int {
        let probe = Array(source[mid..<mid + 4096]), heard = track.mono(delay - 8192 + mid..<delay + 8192 + mid + 4096)
        var scores = [Float](repeating: 0, count: 16385)
        vDSP_conv(heard, 1, probe, 1, &scores, 1, 16385, 4096)
        return delay - 8192 + (scores.indices.max { scores[$0] < scores[$1] } ?? 8192)
    }

    /// Band gains of `source` in `track` over `blocks` equal parts, each lined up on its own: the median of each band.
    /// For noise, so that a part with a dropped or late buffer (seen on a busy machine) does not move the result.
    private static func bandGains(of source: [Float], in track: OutputCapture.Track, blocks: Int) -> [Double] {
        let n = source.count / blocks
        let parts = (0..<blocks).map { k in
            let first = start(of: source, at: k * n + n / 2 - 2048, in: track)
            return Measure.bandGains(input: Array(source[k * n..<(k + 1) * n]), output: track.mono(first + k * n..<first + (k + 1) * n), sampleRate: 44100)
        }
        return parts[0].indices.map { b in
            let v = parts.map { $0[b] }.sorted()
            return (v[(v.count - 1) / 2] + v[v.count / 2]) / 2
        }
    }

    private func noise(seconds: Double) -> [Float] {
        // A fixed sequence (64-bit LCG), so each run plays the same noise.
        var state: UInt64 = 1
        return (0..<Int(seconds * 44100)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53) * 0.2 - 0.1)
        }
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
        let runs = Self.presets.map { start(url, $0.1) }
        try await ended(runs.map(\.mixer))
        for (preset, run) in zip(Self.presets, runs) {
            let track = try run.stop()
            let measured = Self.bandGains(of: source, in: track, blocks: signal == "noise" ? 10 : 1)
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
        try await ended([run.mixer])
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
        try await ended([mixer])
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
        // The time-domain stretch of the outgoing deck moves its clicks by part of a grain: +4 to +11 ms seen.
        #expect(r.beatOffsets.allSatisfy { abs($0) < 15 })
        #expect(r.dip < 3 && r.jump < 3)
        #expect(r.silence < 0.05)
        #expect(r.peak <= 1)
        #expect(r.rateStep < 0.001)
    }
}
