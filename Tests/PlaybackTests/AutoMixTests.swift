import Foundation
@testable import Playback
import Testing

@Suite struct AutoMixTests {
    private func analysis(bpm: Double, duration: Double = 200, introEnd: Double = 12, outroStart: Double = 185,
                          downbeat: Double = 0.5, strength: Double = 0.8) -> SongAnalysis {
        SongAnalysis(duration: duration, soundStart: 0.4, soundEnd: duration - 1, introEnd: introEnd, outroStart: outroStart,
                     bpm: bpm, downbeat: downbeat, beatStrength: strength)
    }

    /// The first beat one of `b` after its start falls on a beat one of `a`, so that all later beats meet too.
    private func barsMeet(_ t: Transition, _ a: SongAnalysis, _ b: SongAnalysis) -> Bool {
        let bar = 240 / b.bpm, outBar = 240 / a.bpm
        let one = b.downbeat + ((t.offset - b.downbeat) / bar - 1e-6).rounded(.up) * bar
        let outTime = t.at + (one - t.offset) / Double(t.rate)
        let bars = (outTime - a.downbeat) / outBar
        let tempoMeets = [0.5, 1, 2].contains { abs(Double(t.rate) * b.bpm * $0 / a.bpm - 1) < 1e-6 }
        return abs(bars - bars.rounded()) * outBar < 0.001 && tempoMeets
    }

    @Test func closeTemposMixForThirtyTwoBeats() throws {
        let a = analysis(bpm: 128, outroStart: 183), b = analysis(bpm: 126, downbeat: 1.3)
        let t = try #require(AutoMix.plan(from: a, to: b))
        #expect(abs(Double(t.rate) - 128 / 126) < 1e-6)
        #expect(abs(t.duration - 15) < 1e-9)  // 32 beats at 128
        #expect(t.offset == 0.4)  // after the silence
        #expect(abs(t.at - 183) < 240 / 128 / 2 + 1e-9)  // at the outro, on a bar
        #expect(t.at + t.duration <= a.duration)
        #expect(t.curve == .equalPower)
        #expect(barsMeet(t, a, b))
    }

    @Test func nearTemposMixForSixteenBeats() throws {
        let a = analysis(bpm: 128), b = analysis(bpm: 123)
        let t = try #require(AutoMix.plan(from: a, to: b))
        #expect(abs(t.duration - 7.5) < 1e-9)
        #expect(t.rate > 1.04 && t.rate < 1.041)
        #expect(barsMeet(t, a, b))
    }

    @Test func halfTimeIsMatched() throws {
        let a = analysis(bpm: 128), b = analysis(bpm: 64.5, downbeat: 2)
        let t = try #require(AutoMix.plan(from: a, to: b))
        #expect(abs(Double(t.rate) - 128 / 129) < 1e-6)
        #expect(barsMeet(t, a, b))
    }

    @Test func farTemposOrWeakBeatsFade() throws {
        let a = analysis(bpm: 128)
        for b in [analysis(bpm: 100), analysis(bpm: 128, strength: 0.05)] {
            let t = try #require(AutoMix.plan(from: a, to: b))
            #expect(t == Transition(at: 185, offset: 0.4, duration: 8, curve: .equalPower, rate: 1))
        }
        // A short outro gives a shorter fade, at the end of the sound.
        let short = try #require(AutoMix.plan(from: analysis(bpm: 128, outroStart: 197), to: analysis(bpm: 90)))
        #expect(short == Transition(at: 195, offset: 0.4, duration: 4, curve: .equalPower, rate: 1))
    }

    @Test func longIntroIsSkippedUpToALimit() throws {
        let a = analysis(bpm: 120)
        let t = try #require(AutoMix.plan(from: a, to: analysis(bpm: 120, introEnd: 25)))
        #expect(abs(t.offset - (25 - 16)) < 1e-9)  // the intro ends with the 16 s mix
        #expect(barsMeet(t, a, analysis(bpm: 120, introEnd: 25)))
        let long = try #require(AutoMix.plan(from: a, to: analysis(bpm: 120, introEnd: 90)))
        #expect(long.offset == 0.4 + AutoMix.maxSkip)
    }

    @Test func streamsThatCannotSeekStartAtZero() throws {
        let a = analysis(bpm: 128), b = analysis(bpm: 127, introEnd: 60, downbeat: 0.9)
        let t = try #require(AutoMix.plan(from: a, to: b, canSeek: false))
        #expect(t.offset == 0)
        #expect(barsMeet(t, a, b))
    }

    @Test func lengthsStayInRange() throws {
        for bpm in stride(from: 70.0, through: 180, by: 5) {
            let a = analysis(bpm: bpm), b = analysis(bpm: bpm * 1.01)
            let t = try #require(AutoMix.plan(from: a, to: b))
            #expect(AutoMix.lengths.contains(t.duration), "\(bpm)")
            #expect(barsMeet(t, a, b), "\(bpm)")
        }
    }

    @Test func shortSongsAreNotMixed() {
        #expect(AutoMix.plan(from: analysis(bpm: 120, duration: 25, introEnd: 2, outroStart: 20), to: analysis(bpm: 120)) == nil)
        #expect(AutoMix.plan(from: analysis(bpm: 120), to: analysis(bpm: 120, duration: 20, introEnd: 2, outroStart: 15)) == nil)
    }

    @Test func settingsChooseAutoMixOrCrossfade() {
        var settings = PlaybackSettings()
        settings.transitions = .autoMix
        let analyses = (analysis(bpm: 128), analysis(bpm: 126))
        let x = song("1", album: "x"), y = song("2", album: "y")
        let mix = settings.transition(from: x, to: y, duration: 200, analyses: analyses, canSeek: true)
        #expect(mix == AutoMix.plan(from: analyses.0, to: analyses.1))
        // Not analyzed yet, or too short: the crossfade.
        let crossfade = settings.transition(from: x, to: y, duration: 200)
        #expect(crossfade?.duration == 6)
        #expect(settings.transition(from: x, to: y, duration: 200, analyses: nil, canSeek: true) == crossfade)
        let short = (analysis(bpm: 128, duration: 20, introEnd: 2, outroStart: 15), analysis(bpm: 126))
        #expect(settings.transition(from: x, to: y, duration: 20, analyses: short, canSeek: true) == settings.transition(from: x, to: y, duration: 20))
        // An album in order stays gapless.
        #expect(settings.transition(from: song("1", track: 1), to: song("2", track: 2), duration: 200, analyses: analyses, canSeek: true) == nil)
        settings.transitions = .crossfade
        #expect(settings.transition(from: x, to: y, duration: 200, analyses: analyses, canSeek: true) == crossfade)
        settings.transitions = .off
        #expect(settings.transition(from: x, to: y, duration: 200, analyses: analyses, canSeek: true) == nil)
    }
}
