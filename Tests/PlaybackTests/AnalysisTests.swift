import Foundation
@testable import Playback
import Testing

@Suite struct AnalysisTests {
    private func check(_ track: ClickTrack, _ a: SongAnalysis) {
        #expect(abs(a.bpm - track.bpm) <= 1, "bpm \(a.bpm) for \(track.bpm)")
        #expect(abs(a.downbeat - track.downbeat) <= 0.03, "downbeat \(a.downbeat) for \(track.downbeat)")
        #expect(abs(a.introEnd - track.introEnd) <= 0.5, "intro end \(a.introEnd) for \(track.introEnd)")
        #expect(abs(a.outroStart - track.outroStart) <= 0.5, "outro start \(a.outroStart) for \(track.outroStart)")
        #expect(abs(a.soundStart - track.lead) <= 0.1, "sound start \(a.soundStart) for \(track.lead)")
        #expect(abs(a.soundEnd - track.soundEnd) <= 0.1, "sound end \(a.soundEnd) for \(track.soundEnd)")
        #expect(abs(a.duration - track.length) <= 0.01)
        #expect(a.beatStrength > 0.5, "strength \(a.beatStrength)")
    }

    @Test(arguments: [120.0, 128, 90, 174, 75])
    func clickTracks(bpm: Double) {
        let track = ClickTrack(bpm: bpm, lead: 1.2, intro: 8, body: 50, outro: 10, trail: 1.5, firstBeat: 0.21, pickup: 1)
        check(track, SongAnalysis(samples: track.samples()))
    }

    @Test func noIntroNoSilence() {
        let track = ClickTrack(bpm: 100, body: 40, firstBeat: 0.05)
        let a = SongAnalysis(samples: track.samples())
        check(track, a)
        #expect(a.introEnd < 0.5)
    }

    @Test func decodesAFile() async throws {
        let track = ClickTrack(bpm: 128, lead: 0.5, intro: 6, body: 30, outro: 6, trail: 1, firstBeat: 0.1, pickup: 3)
        let url = try track.file()
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try await PCMReader.samples(of: url)
        check(track, SongAnalysis(samples: samples))
    }

    @Test func noiseHasNoBeat() {
        var seed: UInt64 = 1
        let noise = (0..<11025 * 40).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) >> 40) / Float(1 << 24) * 0.2
        }
        #expect(SongAnalysis(samples: noise).beatStrength < 0.2)
    }

    @Test func silenceIsSafe() {
        let a = SongAnalysis(samples: [Float](repeating: 0, count: 11025 * 5))
        #expect(a.duration == 5)
        #expect(SongAnalysis(samples: []).duration == 0)
    }
}
