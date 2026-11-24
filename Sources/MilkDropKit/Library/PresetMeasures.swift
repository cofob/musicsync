import Foundation
import Support
import Synchronization

/// On disk, next to the compile index: what rendering each preset on the demo track showed (`PresetMeasure`: its
/// look, mood and flashes), by file (size and date), so a changed preset is measured again. A file of another
/// `version` counts as empty.
public final class PresetMeasures: Sendable {
    /// Raised when the measuring changes (the demo track, the frames judged, the flash rules).
    public static let version = 1

    struct Record: Codable, Sendable { var stamp: String; var measure: PresetMeasure }
    private struct File: Codable { var version: Int; var records: [String: Record] }

    private let url: URL
    private let records: Mutex<[String: Record]>

    private static let shared = Mutex<[URL: PresetMeasures]>([:])

    /// One store per file, shared by everyone who opens it.
    public static func at(_ url: URL) -> PresetMeasures {
        shared.withLock { all in
            if let store = all[url] { return store }
            let store = PresetMeasures(url: url)
            all[url] = store
            return store
        }
    }

    init(url: URL) {
        self.url = url
        let file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        records = Mutex(file?.version == Self.version ? file?.records ?? [:] : [:])
    }

    /// The measure of the preset file as it is now; nil when not made (or the file changed).
    public func measure(_ entry: PresetLibrary.Entry) -> PresetMeasure? {
        let stamp = CompileIndex.stamp(entry.url)
        return records.withLock { $0[entry.name].flatMap { $0.stamp == stamp ? $0.measure : nil } }
    }

    public func mood(_ entry: PresetLibrary.Entry) -> Mood? { measure(entry)?.mood }

    /// Not flashing too much, as far as measured; nil for a preset not measured yet.
    public func isSafe(_ entry: PresetLibrary.Entry) -> Bool? { measure(entry)?.flash.isSafe }

    public func record(_ entry: PresetLibrary.Entry, _ measure: PresetMeasure) {
        let stamp = CompileIndex.stamp(entry.url)
        records.withLock { $0[entry.name] = Record(stamp: stamp, measure: measure) }
    }

    public func save() {
        let data = records.withLock { try? JSONEncoder().encode(File(version: Self.version, records: $0)) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: url, options: .atomic)
    }
}
