import Foundation

/// File layout under `iPod_Control/Music`. Paths are relative to the volume root, `/`-separated.
public struct MusicLayout: Sendable {
    public static let folderCount = 50
    private static let nameAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    public let device: IPodDevice

    public init(device: IPodDevice) { self.device = device }

    /// New unused path like `iPod_Control/Music/F07/ABCD.m4a`. Creates the `Fxx` folder.
    /// FAT32 is case-insensitive, so `existing` is compared case-insensitively.
    public func newMusicFilePath(ext: String, existing: Set<String>) -> String {
        let taken = Set(existing.map(Self.normalize))
        let ext = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        while true {
            let folder = String(format: "F%02d", Int.random(in: 0..<Self.folderCount))
            let name = String((0..<4).map { _ in Self.nameAlphabet.randomElement()! })
            let path = "iPod_Control/Music/\(folder)/\(name).\(ext)"
            if taken.contains(Self.normalize(path)) { continue }
            if FileManager.default.fileExists(atPath: device.mountURL.appendingPathComponent(path).path) { continue }
            try? FileManager.default.createDirectory(
                at: device.musicDir.appendingPathComponent(folder), withIntermediateDirectories: true)
            return path
        }
    }

    /// Creates the standard folders. Only for a freshly formatted test volume.
    public func ensureStructure() throws {
        let fm = FileManager.default
        let dirs = [device.iTunesDir, device.artworkDir, device.deviceDir]
            + (0..<Self.folderCount).map { device.musicDir.appendingPathComponent(String(format: "F%02d", $0)) }
        for dir in dirs { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    /// Files under `Music/F*` that `referenced` does not list. Accepts `/` or iPod `:` separators.
    public func orphans(referenced: Set<String>) throws -> [(path: String, size: Int64)] {
        let known = Set(referenced.map(Self.normalize))
        let fm = FileManager.default
        let folders = try fm.contentsOfDirectory(atPath: device.musicDir.path)
            .filter { $0.hasPrefix("F") }.sorted()
        var result: [(path: String, size: Int64)] = []
        for folder in folders {
            let dir = device.musicDir.appendingPathComponent(folder)
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let path = "iPod_Control/Music/\(folder)/\(file.lastPathComponent)"
                guard !known.contains(Self.normalize(path)) else { continue }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                result.append((path, Int64(size)))
            }
        }
        return result
    }

    private static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: ":", with: "/").lowercased()
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
