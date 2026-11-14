import AVFoundation
@testable import Playback
import Testing

/// Real AVPlayer runs on silent files with the volume at 0: checks timing and deck state, not sound.
@MainActor @Suite(.serialized) final class MixerTests {
    private let mixer = Mixer()
    private var events: [(Mixer.Event, TimeInterval)] = []
    private let start = Date()
    private var files: [URL] = []

    init() {
        mixer.volume = 0
        mixer.onEvent = { [unowned self] in events.append(($0, Date().timeIntervalSince(start))) }
    }

    deinit { files.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func cue(_ seconds: Double) throws -> Mixer.Cue {
        let url = try silentFile(seconds: seconds)
        files.append(url)
        return Mixer.Cue(item: AVPlayerItem(url: url))
    }

    private func missing() -> Mixer.Cue {
        Mixer.Cue(item: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")))
    }

    /// Seconds after the start at which `event` came, waiting up to `timeout`.
    private func time(of event: Mixer.Event, timeout: Double = 6) async -> TimeInterval? {
        for _ in 0..<Int(timeout * 50) {
            if let hit = events.first(where: { $0.0 == event }) { return hit.1 }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// Decks that hold an item and play it.
    private var playingDecks: Int { mixer.decks.count { $0.player.currentItem != nil && $0.player.rate != 0 } }
    private var loadedDecks: Int { mixer.decks.count { $0.player.currentItem != nil } }

    @Test(arguments: [false, true]) func gaplessInOneDeck(equalizer: Bool) async throws {
        mixer.usesEqualizer = equalizer
        mixer.play(try cue(1.5))
        mixer.setNext(try cue(1.5))
        let advanced = try #require(await time(of: .advanced(skipped: false)))
        #expect(advanced > 1.2 && advanced < 2.5)
        #expect(loadedDecks == 1)
        let ended = try #require(await time(of: .ended))
        #expect(ended > 2.7 && ended < 4.5)
        #expect(!mixer.isPlaying)
        #expect(!mixer.hasCurrent)
    }

    @Test func equalizerTapRunsOnBothDecks() async throws {
        mixer.equalizer.set(EqualizerGains(preamp: -3, bands: [6, 0, 0, 0, 0, 0, 0, 0, 0, -6]))
        mixer.usesEqualizer = true
        mixer.play(try cue(2))
        mixer.setNext(try cue(2), transition: Transition(at: 0.8, duration: 0.8, curve: .linear))
        _ = try #require(await time(of: .advanced(skipped: false)))
        await sleep(0.4)
        #expect(playingDecks == 2)
        #expect(mixer.decks.allSatisfy { $0.player.currentItem?.audioMix?.inputParameters.first?.audioTapProcessor != nil })
        // 1.2 s of two decks at 44.1 kHz; the tap gets the audio ahead of the clock.
        #expect(mixer.equalizer.processedFrames > 44100)
        // Off: the current song plays without the tap; the outgoing one keeps it until the fade ends.
        mixer.usesEqualizer = false
        await sleep(0.2)
        #expect(mixer.decks.contains { $0.player.currentItem != nil && $0.player.currentItem?.audioMix == nil })
    }

    @Test func crossfadeOverlapsTwoDecks() async throws {
        mixer.play(try cue(3))
        mixer.setNext(try cue(3), transition: Transition(at: 1, duration: 1, curve: .linear))
        let advanced = try #require(await time(of: .advanced(skipped: false)))
        #expect(advanced > 0.9 - Mixer.lead && advanced < 1.6)
        #expect(mixer.isFading)
        await sleep(0.5)
        #expect(playingDecks == 2)
        let fades = mixer.decks.map(\.fade)
        #expect(fades.allSatisfy { $0 > 0.1 && $0 < 0.9 })
        await sleep(1)
        #expect(!mixer.isFading)
        #expect(loadedDecks == 1)
        #expect(mixer.decks.allSatisfy { $0.fade == 1 })
        #expect(mixer.time > 1 && mixer.time < 2)
    }

    @Test func pauseHoldsTheFade() async throws {
        mixer.play(try cue(3))
        mixer.setNext(try cue(3), transition: Transition(at: 0.5, duration: 1.5, curve: .linear))
        _ = try #require(await time(of: .advanced(skipped: false)))
        await sleep(0.4)
        mixer.pause()
        await sleep(0.1)  // one more step at the time where the decks stopped
        let fades = mixer.decks.map(\.fade)
        await sleep(0.6)
        #expect(playingDecks == 0)
        #expect(mixer.decks.map(\.fade) == fades)
        #expect(mixer.isFading)
        mixer.resume()
        #expect(playingDecks == 2)
        await sleep(1.5)
        #expect(!mixer.isFading)
        #expect(playingDecks == 1)
    }

    @Test(arguments: [false, true]) func seekEndsTheFade(equalizer: Bool) async throws {
        mixer.usesEqualizer = equalizer
        mixer.play(try cue(3))
        mixer.setNext(try cue(3), transition: Transition(at: 0.5, duration: 2))
        _ = try #require(await time(of: .advanced(skipped: false)))
        await sleep(0.3)
        mixer.seek(to: 2)
        #expect(!mixer.isFading)
        #expect(loadedDecks == 1)
        await sleep(equalizer ? 0.5 : 0.3)  // the tap delays a seek, see `Mixer.usesEqualizer`
        #expect(mixer.time > 2)
        #expect(playingDecks == 1)
    }

    @Test(arguments: [false, true]) func fastSkipsLeaveOneDeck(equalizer: Bool) async throws {
        mixer.usesEqualizer = equalizer
        mixer.play(try cue(3))
        mixer.setNext(try cue(3), transition: Transition(at: 0.3, duration: 2))
        _ = try #require(await time(of: .advanced(skipped: false)))
        for _ in 0..<20 {
            mixer.play(try cue(3))
            mixer.setNext(try cue(3), transition: Transition(at: 2, duration: 1))
            if Bool.random() { _ = mixer.skipToNext() }
        }
        await sleep(0.6)
        #expect(!mixer.isFading)
        #expect(playingDecks == 1)
        #expect(mixer.time > 0.2)
    }

    @Test func skipToNextCutsAtOnce() async throws {
        mixer.play(try cue(3))
        mixer.setNext(try cue(3), transition: Transition(at: 2.5, duration: 0.5))
        await sleep(0.3)
        #expect(mixer.skipToNext())
        #expect(events.map(\.0).contains(.advanced(skipped: true)))
        #expect(!mixer.skipToNext())
        await sleep(0.3)
        #expect(playingDecks == 1)
        #expect(mixer.time < 0.6)
    }

    @Test func transitionStartsTheNextSongAtItsOffset() async throws {
        mixer.play(try cue(2))
        mixer.setNext(try cue(3), transition: Transition(at: 0.5, offset: 1.5, duration: 0.5))
        _ = try #require(await time(of: .advanced(skipped: false)))
        await sleep(0.2)
        #expect(mixer.time >= 1.5)
    }

    @Test func failingNextIsDroppedAndTheSongEnds() async throws {
        mixer.play(try cue(1))
        mixer.setNext(missing(), transition: Transition(at: 0.5, duration: 0.5))
        let failed = await failure()
        #expect(failed == false)
        _ = try #require(await time(of: .ended))
        #expect(!events.map(\.0).contains(.advanced(skipped: false)))
        #expect(loadedDecks == 0)
    }

    @Test func retryAfterAFailedNextPlays() async throws {
        let retry = try cue(2)
        mixer.onEvent = { [unowned self] event in
            events.append((event, Date().timeIntervalSince(start)))
            if case .failed(false, _) = event { mixer.setNext(retry, transition: Transition(at: 0.6, duration: 0.3)) }
        }
        mixer.play(try cue(1))
        mixer.setNext(missing(), transition: Transition(at: 0.6, duration: 0.3))
        _ = try #require(await time(of: .advanced(skipped: false)))
        await sleep(0.7)
        #expect(playingDecks == 1)
        #expect(mixer.decks.contains { $0.player.currentItem === retry.item })
    }

    @Test func failingCurrentIsReported() async throws {
        mixer.play(missing())
        #expect(await failure() == true)
    }

    /// `current` of the first failure event.
    private func failure() async -> Bool? {
        for _ in 0..<250 {
            for (event, _) in events { if case .failed(let current, _) = event { return current } }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}
