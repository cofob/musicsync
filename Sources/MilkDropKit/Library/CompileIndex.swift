import Foundation
import Synchronization

/// On disk: which presets compile and which do not, by file (size and date), so broken presets stay out of the list
/// from the start and nothing compiles twice to learn it. The compiled shaders themselves are in the system's
/// Metal shader cache, which keeps them across launches (a preset seen before takes under 1 ms instead of ~180).
public final class CompileIndex: Sendable {
    struct Record: Codable, Sendable { var stamp: String; var ok: Bool; var error: String? }

    private let url: URL
    private let records: Mutex<[String: Record]>

    private static let shared = Mutex<[URL: CompileIndex]>([:])

    /// One index per file, shared by everyone who opens it.
    public static func at(_ url: URL) -> CompileIndex {
        shared.withLock { all in
            if let index = all[url] { return index }
            let index = CompileIndex(url: url)
            all[url] = index
            return index
        }
    }

    private init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        records = Mutex(data.flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:])
    }

    /// What is known about the preset file now: true compiles, false does not, nil not tried (or the file changed).
    public func status(_ entry: PresetLibrary.Entry) -> Bool? {
        let stamp = Self.stamp(entry.url)
        return records.withLock { $0[entry.name].flatMap { $0.stamp == stamp ? $0.ok : nil } }
    }

    public func record(_ entry: PresetLibrary.Entry, ok: Bool, error: String? = nil) {
        let stamp = Self.stamp(entry.url)
        records.withLock { $0[entry.name] = Record(stamp: stamp, ok: ok, error: error) }
    }

    /// Names in `library` known not to compile.
    public func failed(in library: PresetLibrary) -> Set<String> {
        Set(library.entries.values.filter { status($0) == false }.map(\.name))
    }

    public func save() {
        let data = records.withLock { try? JSONEncoder().encode($0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: url, options: .atomic)
    }

    private static func stamp(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}
