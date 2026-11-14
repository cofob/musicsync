import AVFoundation
@testable import Playback
import Testing

/// Real AVPlayer on generated click tracks with the volume at 0: how exactly the incoming song starts.
@MainActor @Suite(.slow, .serialized) final class MixerTimingTests {
    private let mixer = Mixer()
    private var advanced = false
    private var files: [URL] = []

    init() {
        mixer.volume = 0
        mixer.onEvent = { [unowned self] in if $0 == .advanced(skipped: false) { advanced = true } }
    }

    deinit { files.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func cue(_ seconds: Double) async throws -> Mixer.Cue {
        let url = try await ClickTrack(bpm: 120, body: seconds, firstBeat: 0.1).file()
        files.append(url)
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain  // as the app plays
        return Mixer.Cue(item: item)
    }

    private func waitForAdvance() async throws {
        for _ in 0..<300 where !advanced { try await Task.sleep(for: .milliseconds(20)) }
        try #require(advanced)
    }

    private func time(_ item: AVPlayerItem) throws -> Double {
        CMTimebaseGetTime(try #require(item.timebase)).seconds
    }

    /// Seconds the incoming song is late against the outgoing one: 0 when it started exactly at `at`.
    private func startError(_ outgoing: Mixer.Cue, _ incoming: Mixer.Cue, _ t: Transition) throws -> Double {
        let out = try time(outgoing.item), into = try time(incoming.item)
        return (out - t.at) - (into - t.offset) / Double(t.rate)
    }

    @Test(arguments: [Float(1), 1.04, 0.95])
    func incomingStartsOnTime(rate: Float) async throws {
        let a = try await cue(4), b = try await cue(4)
        let t = Transition(at: 1.5, offset: 0.5, duration: 1.5, rate: rate)
        mixer.play(a)
        mixer.setNext(b, transition: t)
        try await waitForAdvance()
        try await Task.sleep(for: .seconds(Mixer.lead + 0.4))
        #expect(mixer.isFading)
        let error = try startError(a, b, t)
        #expect(abs(error) < 0.02, "start error \(error * 1000) ms")
    }

    @Test func pauseBeforeTheTimedStartHolds() async throws {
        let a = try await cue(3), b = try await cue(3)
        mixer.play(a)
        mixer.setNext(b, transition: Transition(at: 1, duration: 1))
        try await waitForAdvance()
        mixer.pause()
        try await Task.sleep(for: .seconds(Mixer.lead + 0.3))
        #expect(mixer.decks.allSatisfy { $0.player.rate == 0 })
        #expect(mixer.time < 0.05)
    }

    @Test func rateStaysAfterTheFade() async throws {
        let a = try await cue(3), b = try await cue(4)
        mixer.play(a)
        mixer.setNext(b, transition: Transition(at: 0.6, duration: 0.5, rate: 1.05))
        try await waitForAdvance()
        try await Task.sleep(for: .seconds(Mixer.lead + 0.2))
        let deck = try #require(mixer.decks.first { $0.player.currentItem === b.item })
        #expect(deck.player.rate == 1.05)
        try await Task.sleep(for: .seconds(1))
        #expect(!mixer.isFading)
        #expect(deck.player.rate == 1.05 && mixer.nudge == 1.05)
        mixer.pause()
        mixer.resume()
        #expect(deck.player.rate == 1.05)
    }

    @Test func retimeMovesTheTransition() async throws {
        let a = try await cue(4), b = try await cue(4)
        mixer.play(a)
        mixer.setNext(b, transition: Transition(at: 3, duration: 0.5))
        try await Task.sleep(for: .seconds(0.3))
        mixer.retime(Transition(at: 0.2, duration: 1))  // due already: ignored
        let t = Transition(at: 1.2, offset: 1, duration: 1)
        mixer.retime(t)
        try await waitForAdvance()
        try await Task.sleep(for: .seconds(Mixer.lead + 0.3))
        #expect(mixer.time > 1.1 && mixer.time < 1.5)
        #expect(abs(try startError(a, b, t)) < 0.02)
    }
}
