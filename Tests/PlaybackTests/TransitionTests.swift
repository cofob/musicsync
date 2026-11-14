import Playback
import Testing

@Suite struct TransitionTests {
    private var crossfade: PlaybackSettings {
        var s = PlaybackSettings()
        s.crossfade = true
        s.crossfadeSeconds = 6
        return s
    }

    @Test func offIsGapless() {
        #expect(PlaybackSettings().transition(from: song("1", album: "x"), to: song("2", album: "y"), duration: 200) == nil)
    }

    @Test func crossfadeBeforeTheEnd() {
        let t = crossfade.transition(from: song("1", album: "x"), to: song("2", album: "y"), duration: 200)
        #expect(t == Transition(at: 194, offset: 0, duration: 6, curve: .equalPower, rate: 1))
        // A short song gets at most half its length.
        #expect(crossfade.transition(from: song("1", album: "x"), to: song("2", album: "y"), duration: 8)?.duration == 4)
    }

    @Test func noCrossfadeInAlbumOrderOrWithoutLength() {
        #expect(crossfade.transition(from: song("1", track: 1), to: song("2", track: 2), duration: 200) == nil)
        #expect(crossfade.transition(from: song("1"), to: song("1"), duration: 200) == nil)
        #expect(crossfade.transition(from: song("1", album: "x"), to: song("2", album: "y"), duration: nil) == nil)
        // Shuffle can play the same album backwards: that is crossfaded.
        #expect(crossfade.transition(from: song("2", track: 2), to: song("1", track: 1), duration: 200) != nil)
    }

    @Test func curves() {
        #expect(FadeCurve.linear.volumes(at: 0.25) == (0.75, 0.25))
        let mid = FadeCurve.equalPower.volumes(at: 0.5)
        #expect(abs(mid.out - mid.in) < 1e-9)
        #expect(abs(mid.out * mid.out + mid.in * mid.in - 1) < 1e-9)
        #expect(FadeCurve.equalPower.volumes(at: 2) == FadeCurve.equalPower.volumes(at: 1))
    }
}
