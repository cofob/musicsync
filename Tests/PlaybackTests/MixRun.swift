import AVFoundation
@testable import Playback
import Testing

/// Plays song `a` into song `b` along a transition on a real, muted mixer and measures the output around the overlap.
@MainActor struct MixRun {
    struct Song {
        var cue: Mixer.Cue
        /// The song's audio as mono at `sampleRate` from time `sourceStart`: places the tap recording in item time.
        var source: [Float]
        var sampleRate = 44100.0
        var sourceStart = 0.0
    }

    struct Result {
        /// Beat offsets of `b` against `a` per 4 s of the overlap, ms; empty for a fade.
        var beatOffsets: [Double] = []
        /// How far the 400 ms level in the overlap falls below and rises above the levels before and after it, dB.
        var dip = 0.0, jump = 0.0
        /// Largest change between neighboring 400 ms windows around the overlap, dB.
        var step = 0.0
        /// Longest silence, s, and the highest sample.
        var silence = 0.0, peak: Float = 0
        /// Seconds from the overlap start to the highest sample, and each deck's highest sample.
        var peakAt = 0.0, deckPeaks: (Float, Float) = (0, 0)
        /// Largest rate change within 50 ms on the deck of `b` from its start.
        var rateStep = 0.0
        /// How late `b` started against the plan, ms (item timebases).
        var startError = 0.0
        /// How far the heard item time is ahead of the tap stamps for `a` and `b`, ms.
        var shifts = (0.0, 0.0)
        /// How far a second line-up of the recording, later on, moves from the first one, for `a` and `b`, ms.
        var drift = (0.0, 0.0)
        var render: OutputCapture.Render?

        var summary: String {
            let beats = beatOffsets.map { String(format: "%+.1f", $0) }.joined(separator: " ")
            return String(format: "beats [%@] ms, dip %.1f dB, jump %.1f dB, step %.1f dB, silence %.0f ms, peak %.3f at %+.2f s (decks %.3f/%.3f), rate step %.5f, start %+.1f ms, shifts %.1f/%.1f ms, drift %.2f/%.2f ms",
                          beats, dip, jump, step, silence * 1000, peak, peakAt, deckPeaks.0, deckPeaks.1, rateStep, startError, shifts.0, shifts.1)
        }
    }

    var a: Song
    var b: Song
    var transition: Transition
    /// Tempo of `a` for the beat offsets; nil for a fade.
    var bpm: Double?
    /// Seconds of `a` before the transition, and of `b` after it, that are measured.
    var before = 6.0, after = 10.0
    let recorder = TapRecorder()

    func run(wav name: String? = nil) async throws -> Result {
        let mixer = Mixer(equalizer: Equalizer(recorder: recorder))
        mixer.volume = 0
        mixer.usesEqualizer = true  // flat: the tap records and leaves the sound as it is
        let capture = OutputCapture(mixer: mixer, recorder: recorder)
        let t = transition
        mixer.play(a.cue)
        try await wait { a.cue.item.status == .readyToPlay && mixer.time > 0.05 }
        mixer.seek(to: max(t.at - before - 0.5, 0))
        try await wait { abs(mixer.time - (t.at - before - 0.5)) < 0.3 || t.at < before + 0.5 }
        capture.start()
        mixer.setNext(b.cue, transition: t)
        try await wait(timeout: t.at + 30) { mixer.isFading }
        try await wait(timeout: 40) { !mixer.isFading }
        try await Task.sleep(for: .seconds(after + 0.5))
        capture.stop()

        var tracks = capture.tracks()
        let ia = ObjectIdentifier(a.cue.item), ib = ObjectIdentifier(b.cue.item)
        let start = max(t.at - before, 0)
        var result = Result()
        let from = try #require(capture.host(of: a.cue.item, at: start))
        let overlap = try #require(capture.host(of: b.cue.item, at: t.offset))
        let trackA = try #require(tracks[ia]), trackB = try #require(tracks[ib])
        let anchorA = try #require(capture.anchor(trackA, of: ia, source: a.source, sourceRate: a.sampleRate, sourceStart: a.sourceStart, from: from + 0.5))
        let anchorB = try #require(capture.anchor(trackB, of: ib, source: b.source, sourceRate: b.sampleRate, sourceStart: b.sourceStart, from: overlap + 0.3))
        tracks[ia]?.anchor = anchorA.anchor
        tracks[ib]?.anchor = anchorB.anchor
        result.shifts = (anchorA.latency * 1000, anchorB.latency * 1000)
        let lateA = capture.anchor(trackA, of: ia, source: a.source, sourceRate: a.sampleRate, sourceStart: a.sourceStart, from: overlap - 3.2)
        let lateB = capture.anchor(trackB, of: ib, source: b.source, sourceRate: b.sampleRate, sourceStart: b.sourceStart, from: overlap + t.duration + 1)
        result.drift = (((lateA?.anchor ?? .nan) - anchorA.anchor) * 1000, ((lateB?.anchor ?? .nan) - anchorB.anchor) * 1000)

        let overlapEnd = overlap + t.duration
        let to = min(overlapEnd + after, capture.polls.last?.host ?? overlapEnd)
        let render = capture.render(tracks, from: from, to: to)
        result.render = render
        result.startError = (capture.host(of: a.cue.item, at: t.at).map { overlap - $0 } ?? .nan) * 1000

        let deckA = try #require(capture.polls.first?.decks.firstIndex { $0.item == ia })
        let out = render.decks[deckA], into = render.decks[1 - deckA]
        let o0 = render.frame(overlap), o1 = render.frame(overlapEnd)
        if let bpm { result.beatOffsets = Measure.beatOffsets(Array(out[2 * o0..<2 * o1]), Array(into[2 * o0..<2 * o1]), sampleRate: render.sampleRate, bpm: bpm) }

        let levels = Measure.levels(render.mix, sampleRate: render.sampleRate)
        let time = { (i: Int) in from + Double(i) * 0.1 + 0.2 }  // window centers
        func median(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.sorted()[x.count / 2] }
        let pre = median(levels.indices.filter { time($0) < overlap - 0.5 }.map { levels[$0] })
        let post = median(levels.indices.filter { time($0) > overlapEnd + 0.5 }.map { levels[$0] })
        let inside = levels.indices.filter { time($0) >= overlap && time($0) <= overlapEnd }.map { levels[$0] }
        result.dip = min(pre, post) - (inside.min() ?? .nan)
        result.jump = (inside.max() ?? .nan) - max(pre, post)
        let around = levels.indices.filter { time($0) >= overlap - 1 && time($0) <= overlapEnd + 1 && $0 + 4 < levels.count }
        result.step = around.map { abs(levels[$0 + 4] - levels[$0]) }.max() ?? 0
        result.silence = Measure.longestSilence(render.mix, sampleRate: render.sampleRate)
        result.peak = Measure.peak(render.mix)
        if let i = render.mix.indices.max(by: { abs(render.mix[$0]) < abs(render.mix[$1]) }) {
            result.peakAt = render.host(i / 2) - overlap
        }
        result.deckPeaks = (Measure.peak(out), Measure.peak(into))
        let rates = capture.polls.compactMap { p -> (time: Double, rate: Double)? in
            guard p.host >= overlap - 0.1, let s = p.decks.first(where: { $0.item == ib }) else { return nil }
            return (p.host, Double(s.playerRate))
        }
        result.rateStep = Measure.maxRateStep(rates)

        if let name, let folder = OutputCapture.wavFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try OutputCapture.write(render.mix, sampleRate: render.sampleRate, to: folder.appendingPathComponent("\(name).wav"))
        }
        mixer.stop()
        return result
    }

    private func wait(timeout: Double = 10, until condition: () -> Bool) async throws {
        for _ in 0..<Int(timeout * 50) where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}
