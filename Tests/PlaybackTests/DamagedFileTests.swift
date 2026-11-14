import Foundation
@testable import Playback
import Testing

/// Damaged cache and queue files are ignored, never trusted.
@Suite final class DamagedFileTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("damaged-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private let junk = [Data(), Data("garbage".utf8), Data([0xff, 0x00, 0xfe]), Data("{}".utf8), Data("null".utf8),
                        Data(#"{"version":1,"analysis":{"duration":"x"}}"#.utf8)]

    private func analysis(bpm: Double = 120, soundEnd: Double = 199) -> SongAnalysis {
        SongAnalysis(duration: 200, soundStart: 0.5, soundEnd: soundEnd, introEnd: 10, outroStart: 180, bpm: bpm, downbeat: 0.2, beatStrength: 0.9)
    }

    @Test func analysisCacheIgnoresDamagedFiles() throws {
        let cache = AnalysisCache(directory: directory)
        for data in junk {
            try data.write(to: cache.url("a"))
            #expect(cache.read("a") == nil)
        }
        // Values the analysis never makes: a mix plan with them could loop for ever.
        for bad in [analysis(bpm: 1e300), analysis(bpm: 0), analysis(soundEnd: 1e9)] {
            cache.write(bad, for: "a")
            #expect(cache.read("a") == nil)
        }
        cache.write(analysis(), for: "a")
        #expect(cache.read("a") == analysis())
    }

    @Test func queueSnapshotIgnoresDamagedFiles() throws {
        let url = directory.appendingPathComponent("queue.json")
        for data in junk + [Data(#"{"server":"s","items":["a"],"origins":[],"index":0,"elapsed":1e400,"shuffle":false,"repeatMode":"x"}"#.utf8)] {
            try data.write(to: url)
            #expect(QueueSnapshot<String>.load(from: url) == nil)
        }
    }

    @Test func queueSnapshotWithOddNumbersStaysInRange() throws {
        for index in [-5, 0, 2, 99, Int.max, Int.min] {
            let saved = QueueSnapshot(server: "s", items: ["a", "b", "c"], origins: [.user], index: index, elapsed: -3,
                                      shuffle: false, repeatMode: "nonsense")
            let kept = try #require(saved.filtered { _ in true })
            #expect(kept.items.indices.contains(kept.index) && kept.origins.count == 3)
            let queue = PlayQueue(items: kept.items, origins: kept.origins, index: kept.index)
            #expect(queue.index == kept.index)
        }
    }
}
