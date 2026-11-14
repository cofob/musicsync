import Foundation
import Playback
import Subsonic
import Testing

@Suite struct GainTests {
    private let tagged = song("a", gain: ["trackGain": -6, "albumGain": -8, "trackPeak": 0.5, "albumPeak": 0.9])

    private func settings(_ mode: PlaybackSettings.SoundCheck, preAmp: Double = 0, clip: Bool = true) -> PlaybackSettings {
        var s = PlaybackSettings()
        s.soundCheck = mode
        s.preAmp = preAmp
        s.preventClipping = clip
        return s
    }

    @Test func offOrUntaggedIsUnity() {
        #expect(settings(.off).gain(for: tagged, inAlbumOrder: true) == 1)
        #expect(settings(.track).gain(for: song("b"), inAlbumOrder: false) == 1)
        #expect(settings(.track).gain(for: nil, inAlbumOrder: false) == 1)
    }

    @Test func trackAndAlbumGain() {
        #expect(abs(settings(.track).gain(for: tagged, inAlbumOrder: true) - 0.501) < 0.001)
        #expect(abs(settings(.album).gain(for: tagged, inAlbumOrder: true) - 0.398) < 0.001)
        // Album mode outside an album in order uses the track gain.
        #expect(settings(.album).gain(for: tagged, inAlbumOrder: false) == settings(.track).gain(for: tagged, inAlbumOrder: false))
        // A missing value falls back to the other one, then to `fallbackGain`.
        #expect(abs(settings(.album).gain(for: song("c", gain: ["trackGain": -6]), inAlbumOrder: true) - 0.501) < 0.001)
        #expect(abs(settings(.track).gain(for: song("d", gain: ["fallbackGain": -20]), inAlbumOrder: false) - 0.1) < 0.001)
    }

    @Test func preAmpPeakAndCap() {
        // +12 dB pre-amp: +6 dB is 2.0, the peak 0.5 allows 2.0, and the cap is 1.
        #expect(settings(.track, preAmp: 12).gain(for: tagged, inAlbumOrder: false) == 1)
        // A peak above full scale lowers the gain when clipping is prevented.
        let hot = song("e", gain: ["trackGain": 0, "trackPeak": 1.25])
        #expect(settings(.track).gain(for: hot, inAlbumOrder: false) == 0.8)
        #expect(settings(.track, clip: false).gain(for: hot, inAlbumOrder: false) == 1)
        #expect(abs(settings(.track, preAmp: -6).gain(for: hot, inAlbumOrder: false) - 0.501) < 0.001)
    }

    @Test func albumSequence() {
        #expect(isAlbumSequence(song("1", track: 1), song("2", track: 2)))
        #expect(isAlbumSequence(song("1", track: 12, disc: 1), song("2", track: 1, disc: 2)))
        #expect(!isAlbumSequence(song("2", track: 2), song("1", track: 1)))
        #expect(!isAlbumSequence(song("1", album: "x"), song("2", album: "y", track: 2)))
        #expect(!isAlbumSequence(song("1", album: nil), song("2", album: nil, track: 2)))
        #expect(!isAlbumSequence(song("1"), song("1")))
        #expect(!isAlbumSequence(song("1"), nil))
    }
}
