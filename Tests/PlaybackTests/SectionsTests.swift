import Foundation
@testable import Playback
import Testing

@Suite struct SectionsTests {
    static let rate = 11025.0

    /// 120 bpm clicks over parts of 20 s each: `true` parts are a low tone, `false` parts a bright chord.
    private func song(_ parts: [Bool]) -> [Float] {
        (0..<Int(Double(parts.count) * 20 * Self.rate)).map { i in
            let t = Double(i) / Self.rate
            let low = parts[Int(t / 20)]
            var x = low ? 0.15 * sin(2 * .pi * 220 * t)
                        : 0.05 * (sin(2 * .pi * 1200 * t) + sin(2 * .pi * 1700 * t) + sin(2 * .pi * 2500 * t))
            let dt = t.truncatingRemainder(dividingBy: 0.5)
            if dt < 0.03 { x += 0.5 * sin(2 * .pi * 1500 * dt) * exp(-dt / 0.006) }
            return Float(x)
        }
    }

    @Test func findsChangesOfSound() {
        let a = SongAnalysis(samples: song([true, false, true]))
        #expect(a.sections.count == 2, "sections \(a.sections)")
        for (found, expected) in zip(a.sections, [20.0, 40.0]) { #expect(abs(found - expected) <= 2, "\(found) for \(expected)") }
        // On bar lines: 2 s apart at 120 bpm.
        for t in a.sections { #expect(abs(((t - a.downbeat) / 2).rounded() * 2 - (t - a.downbeat)) < 0.01) }
    }

    @Test func steadySongHasNone() {
        let track = ClickTrack(bpm: 120, body: 60)
        #expect(SongAnalysis(samples: track.samples(rate: Self.rate)).sections.isEmpty)
    }

    @Test func shortSongHasNone() {
        #expect(SongAnalysis(samples: song([true])).sections.isEmpty)
    }

    @Test func cacheKeepsSections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AnalysisCache(directory: directory)
        let a = SongAnalysis(samples: song([true, false]))
        cache.write(a, for: "x")
        #expect(cache.read("x") == a)
    }
}
