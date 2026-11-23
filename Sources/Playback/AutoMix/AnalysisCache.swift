import Foundation
import Subsonic

/// AutoMix analyses on disk, one small JSON file per song. A result of another analysis version counts as missing.
public struct AnalysisCache: Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private struct Entry: Codable {
        var version: Int
        var analysis: SongAnalysis
    }

    /// The song's id with its file size and length: a changed file is analyzed again.
    public static func key(for song: Song) -> String { "\(song.id)-\(song.size ?? 0)-\(song.duration ?? 0)" }

    public func read(_ key: String) -> SongAnalysis? {
        guard let data = try? Data(contentsOf: url(key)), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == SongAnalysis.version else { return nil }
        // A damaged file may hold values the analysis never makes; with those a mix plan could loop for ever.
        let a = entry.analysis
        guard Beat.tempos.contains(a.bpm), 0 <= a.soundStart, a.soundStart <= a.soundEnd, a.soundEnd <= a.duration + 1,
              a.sections == a.sections.sorted(), a.sections.allSatisfy({ 0...a.duration + 1 ~= $0 }) else { return nil }
        return a
    }

    public func write(_ analysis: SongAnalysis, for key: String) {
        guard let data = try? JSONEncoder().encode(Entry(version: SongAnalysis.version, analysis: analysis)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(key), options: .atomic)
    }

    func url(_ key: String) -> URL {
        directory.appendingPathComponent((key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key) + ".json")
    }
}
