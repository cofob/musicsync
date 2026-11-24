import Foundation
@testable import Playback
import Support
import Testing

@Suite struct MoodTests {
    static let rate = 11025.0

    /// A chord of the given notes (Hz) with `harmonics` overtones at 1 / h^`slope`, and a click on every beat at `bpm`.
    private func music(seconds: Double, notes: [Double], level: Double, harmonics: Int, slope: Double, bpm: Double, click: Double) -> [Float] {
        let period = 60 / bpm
        return (0..<Int(seconds * Self.rate)).map { i in
            let t = Double(i) / Self.rate
            var x = 0.0
            for f in notes { for h in 1...harmonics { x += level / Double(notes.count) * sin(2 * .pi * f * Double(h) * t) / pow(Double(h), slope) } }
            let dt = t.truncatingRemainder(dividingBy: period)
            if dt < 0.03 { x += click * sin(2 * .pi * 1500 * dt) * exp(-dt / 0.006) }
            return Float(x)
        }
    }

    private func loudFastMajor() -> [Float] {
        music(seconds: 40, notes: [261.6, 329.6, 392.0], level: 0.5, harmonics: 6, slope: 0.5, bpm: 160, click: 0.6)
    }

    private func quietSlowMinor() -> [Float] {
        music(seconds: 40, notes: [110.0, 130.8, 164.8], level: 0.03, harmonics: 3, slope: 2, bpm: 72, click: 0.01)
    }

    @Test func loudFastMajorIsMoreEnergeticAndBrighter() throws {
        let loud = try #require(SongAnalysis(samples: loudFastMajor()).mood)
        let quiet = try #require(SongAnalysis(samples: quietSlowMinor()).mood)
        #expect(loud.arousal > quiet.arousal + 0.3, "arousal \(loud.arousal) \(quiet.arousal)")
        #expect(loud.valence > quiet.valence + 0.2, "valence \(loud.valence) \(quiet.valence)")
    }

    @Test func clusterOfSemitonesIsMoreTenseThanAChord() throws {
        let chord = music(seconds: 30, notes: [261.6, 329.6, 392.0], level: 0.2, harmonics: 3, slope: 1, bpm: 100, click: 0)
        let cluster = music(seconds: 30, notes: [261.6, 277.2, 293.7], level: 0.2, harmonics: 3, slope: 1, bpm: 100, click: 0)
        let calm = try #require(SongAnalysis(samples: chord).mood), tense = try #require(SongAnalysis(samples: cluster).mood)
        #expect(tense.tension > calm.tension + 0.2, "tension \(tense.tension) \(calm.tension)")
    }

    @Test func moodsAreInRangeAndPartsMatchSections() throws {
        let a = SongAnalysis(samples: loudFastMajor() + quietSlowMinor())
        let mood = try #require(a.mood)
        #expect([mood.arousal, mood.valence, mood.tension].allSatisfy { 0...1 ~= $0 })
        #expect(a.partMoods.count == a.sections.count + 1)
        // The loud part first, the quiet one after the change.
        #expect(a.sections.count == 1)
        #expect(try #require(a.partMoods.first).arousal > a.partMoods[1].arousal)
        let (part, song) = try #require(a.moods(at: 70))
        #expect(part == a.partMoods[1] && song == mood)
    }

    @Test func silenceHasNoMood() {
        #expect(SongAnalysis(samples: [Float](repeating: 0, count: 200_000)).mood == nil)
    }

    @Test func majorFitsMajorKey() {
        let cMajor = [1, 0, 0.3, 0, 0.6, 0.4, 0, 0.8, 0, 0.3, 0, 0.2]
        let aMinor = [0.8, 0, 0.3, 0.3, 0, 0.4, 0, 0.6, 0.3, 1, 0, 0.1]
        #expect(MoodMeter.majorness(cMajor) > 0 && MoodMeter.majorness(aMinor) < 0)
    }

    @Test func cacheKeepsMood() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mood-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AnalysisCache(directory: directory)
        let a = SongAnalysis(samples: loudFastMajor())
        #expect(a.mood != nil)
        cache.write(a, for: "m")
        #expect(cache.read("m") == a)
    }
}
