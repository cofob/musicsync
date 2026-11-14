import Foundation
@testable import Playback
import Testing

@MainActor @Suite final class AnalysisQueueTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automix-test-\(UUID().uuidString)")
    private var files: [URL] = []

    deinit {
        try? FileManager.default.removeItem(at: directory)
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func clickFile(bpm: Double = 128) async throws -> URL {
        let url = try await ClickTrack(bpm: bpm, lead: 0.5, intro: 4, body: 30, outro: 4, trail: 0.5, firstBeat: 0.1).file()
        files.append(url)
        return url
    }

    private func results(of queue: AnalysisQueue, _ keys: Set<String>) async -> Bool {
        for _ in 0..<500 where !keys.isSubset(of: Set(queue.results.keys)) { try? await Task.sleep(for: .milliseconds(20)) }
        return keys.isSubset(of: Set(queue.results.keys))
    }

    @Test func analyzesAndCaches() async throws {
        let queue = AnalysisQueue(cache: AnalysisCache(directory: directory))
        var reported: [String] = []
        queue.onResult = { reported.append($0) }
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav")
        // A failing song does not hold up the next one.
        queue.want([.init(key: "bad", source: missing), .init(key: "a", source: try await clickFile())])
        #expect(await results(of: queue, ["a"]))
        #expect(reported == ["a"])
        #expect(abs((queue.results["a"]?.bpm ?? 0) - 128) <= 1)
        #expect(FileManager.default.fileExists(atPath: AnalysisCache(directory: directory).url("a").path))

        // Another queue reads it from the disk, without the audio.
        let again = AnalysisQueue(cache: AnalysisCache(directory: directory))
        again.want([.init(key: "a", source: missing)])
        #expect(await results(of: again, ["a"]))
        #expect(again.results["a"] == queue.results["a"])

        queue.want([])
        #expect(queue.results.isEmpty)
    }

    @Test func otherVersionsAreMissing() throws {
        let cache = AnalysisCache(directory: directory)
        let analysis = SongAnalysis(duration: 100, soundStart: 0, soundEnd: 100, introEnd: 5, outroStart: 90, bpm: 120, downbeat: 0.2, beatStrength: 0.8)
        cache.write(analysis, for: "song/1-200-100")
        #expect(cache.read("song/1-200-100") == analysis)
        let old = try String(contentsOf: cache.url("song/1-200-100"), encoding: .utf8)
            .replacingOccurrences(of: "\"version\":\(SongAnalysis.version)", with: "\"version\":0")
        try old.write(to: cache.url("song/1-200-100"), atomically: true, encoding: .utf8)
        #expect(cache.read("song/1-200-100") == nil)
    }

    @Test func downloadsUpToTheCap() async throws {
        let source = try await clickFile()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int)
        let copy = try await AnalysisQueue.download(source, session: .shared, maxBytes: size)
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
        await #expect(throws: AnalysisError.self) { try await AnalysisQueue.download(source, session: .shared, maxBytes: size - 1) }
    }

    @Test func aSongThatIsNotWantedStops() async throws {
        let queue = AnalysisQueue(cache: AnalysisCache(directory: directory))
        queue.want([.init(key: "a", source: try await clickFile())])
        queue.want([.init(key: "b", source: try await clickFile(bpm: 90))])
        #expect(await results(of: queue, ["b"]))
        try await Task.sleep(for: .milliseconds(300))
        #expect(queue.results["a"] == nil)
        #expect(abs((queue.results["b"]?.bpm ?? 0) - 90) <= 1)
    }
}
