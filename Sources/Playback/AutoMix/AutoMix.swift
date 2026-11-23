import Foundation
import Subsonic

/// Plans DJ-style transitions from the analysis of two songs. The mix starts at the outgoing song's outro, and the
/// incoming song skips its silence (and part of a long intro). When the tempos are close, the incoming song plays at
/// the outgoing tempo with its bars on the outgoing bars; else the songs fade over a shorter time.
public enum AutoMix {
    /// Shorter songs are crossfaded.
    static let minimumLength: TimeInterval = 30
    /// Tempos further apart are not beat-matched.
    static let maxNudge = 0.06
    /// Tempos this close can mix for 32 beats.
    static let closeTempo = 0.02
    /// Songs with a weaker beat (`SongAnalysis.beatStrength`) are not beat-matched.
    static let minBeatStrength = 0.15
    static let lengths: ClosedRange<TimeInterval> = 4...16
    /// Shorter intros play whole; of a longer one at most `maxSkip` is skipped.
    static let longIntro: TimeInterval = 20
    static let maxSkip: TimeInterval = 15
    /// Most of the outgoing sound after the mix that is cut.
    static let maxCut: TimeInterval = 30

    /// Transition from `a` into `b`; nil for songs too short to mix. `canSeek` false starts `b` at 0 (a converted stream).
    /// `a` plays at `outgoingRate` (the rate of its own mix in): the incoming rate matches the tempo heard.
    public static func plan(from a: SongAnalysis, to b: SongAnalysis, canSeek: Bool = true, outgoingRate: Double = 1) -> Transition? {
        let heard = a.played(at: outgoingRate)
        guard heard.duration >= minimumLength, b.duration >= minimumLength else { return nil }
        var t = tempoMatch(heard, b).map { beatMix(heard, b, rate: $0, canSeek: canSeek) } ?? fade(heard, b, canSeek: canSeek)
        t.at *= outgoingRate
        return t
    }

    /// Rate of `b` that plays it at the tempo of `a`, also at half or double time; nil when that is more than `maxNudge` away.
    static func tempoMatch(_ a: SongAnalysis, _ b: SongAnalysis) -> Double? {
        guard a.beatStrength >= minBeatStrength, b.beatStrength >= minBeatStrength else { return nil }
        let rate = [0.5, 1, 2].map { a.bpm / (b.bpm * $0) }.min { abs(log($0)) < abs(log($1)) } ?? 1
        return abs(rate - 1) <= maxNudge ? rate : nil
    }

    /// 8, 16 or 32 beats of `a`: as long as its outro or the intro of `b`, within `lengths`; 32 only for close tempos.
    private static func beatMix(_ a: SongAnalysis, _ b: SongAnalysis, rate: Double, canSeek: Bool) -> Transition {
        let beat = 60 / a.bpm
        let available = max(a.soundEnd - a.outroStart, b.introEnd - b.soundStart)
        let limit = min(lengths.upperBound, max(available, lengths.lowerBound))
        let counts = [32, 16, 8].filter { (abs(rate - 1) <= closeTempo || $0 <= 16) && lengths.contains(Double($0) * beat) }
        let duration = Double(counts.first { Double($0) * beat <= limit } ?? counts.last ?? 16) * beat
        let offset = canSeek ? start(b, mixLength: duration * rate) : 0
        // Seconds from the mix start to the next beat one of `b`, which lands on a beat one of `a` near the planned start.
        let bar = 4 * 60 / b.bpm, outBar = 4 * beat
        let lead = (b.downbeat + ((offset - b.downbeat) / bar - 1e-6).rounded(.up) * bar - offset) / rate
        var one = a.downbeat + ((mixStart(a, duration: duration) + lead - a.downbeat) / outBar).rounded() * outBar
        while one - lead + duration > a.duration, one - lead - outBar > 0 { one -= outBar }
        return Transition(at: max(one - lead, 0), offset: offset, duration: duration, curve: .equalPower, rate: Float(rate))
    }

    /// Equal-power fade over the outgoing outro, 4–8 s, for songs whose beats do not match.
    private static func fade(_ a: SongAnalysis, _ b: SongAnalysis, canSeek: Bool) -> Transition {
        let duration = min(max(a.soundEnd - a.outroStart, 4), 8)
        let offset = canSeek ? start(b, mixLength: duration) : 0
        return Transition(at: max(min(mixStart(a, duration: duration), a.duration - duration), 0), offset: offset, duration: duration)
    }

    /// The outro start, or earlier so that `a` is gone at the end of its sound; at most `maxCut` early.
    private static func mixStart(_ a: SongAnalysis, duration: TimeInterval) -> TimeInterval {
        let end = a.soundEnd - duration
        return max(min(a.outroStart, end), end - maxCut, a.soundStart)
    }

    /// After the silence of `b`. An intro longer than `longIntro` is skipped so that it ends with the mix, by at most `maxSkip`.
    private static func start(_ b: SongAnalysis, mixLength: TimeInterval) -> TimeInterval {
        let intro = b.introEnd - b.soundStart
        return b.soundStart + (intro > longIntro ? min(max(intro - mixLength, 0), maxSkip) : 0)
    }
}

private extension SongAnalysis {
    /// The song as heard at `rate`: shorter times, a faster tempo.
    func played(at rate: Double) -> SongAnalysis {
        SongAnalysis(duration: duration / rate, soundStart: soundStart / rate, soundEnd: soundEnd / rate, introEnd: introEnd / rate,
                     outroStart: outroStart / rate, bpm: bpm * rate, downbeat: downbeat / rate, beatStrength: beatStrength,
                     sections: sections.map { $0 / rate })
    }
}

public extension PlaybackSettings {
    /// AutoMix from `song` into `next` when both are analyzed, else the crossfade of `transition(from:to:duration:)`,
    /// which also keeps albums in order gapless. `canSeek` false starts `next` at its beginning; `song` plays at `outgoingRate`.
    func transition(from song: Song?, to next: Song?, duration: TimeInterval?, analyses: (SongAnalysis, SongAnalysis)?,
                    canSeek: Bool, outgoingRate: Double = 1) -> Transition? {
        guard let crossfade = transition(from: song, to: next, duration: duration) else { return nil }
        guard transitions == .autoMix, let analyses else { return crossfade }
        return AutoMix.plan(from: analyses.0, to: analyses.1, canSeek: canSeek, outgoingRate: outgoingRate) ?? crossfade
    }
}
