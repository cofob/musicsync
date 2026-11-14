import Device
import Foundation

/// Copies of the device databases kept on the Mac before every write.
enum Backups {
    static let keep = 10

    /// Backs up iTunesDB, ArtworkDB, Play Counts and the manifest; prunes to the newest `keep` folders.
    @discardableResult
    static func create(device: IPodDevice, root: URL, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var dir = root.appendingPathComponent(formatter.string(from: now))
        var n = 1
        while FileManager.default.fileExists(atPath: dir.path) {
            n += 1
            dir = root.appendingPathComponent("\(formatter.string(from: now))-\(n)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sources = [device.iTunesDBURL, device.playCountsURL, device.artworkDir.appendingPathComponent("ArtworkDB"),
                       ManifestStore.url(for: device)]
        for source in sources where FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(source.lastPathComponent))
        }
        prune(root: root)
        return dir
    }

    static func prune(root: URL) {
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for name in all.dropLast(keep) { try? fm.removeItem(at: root.appendingPathComponent(name)) }
    }

    /// One-time copy of the original database on the iPod itself.
    static func keepOriginal(device: IPodDevice) {
        let copy = device.iTunesDir.appendingPathComponent("iTunesDB.musicsync-orig")
        let fm = FileManager.default
        if fm.fileExists(atPath: device.iTunesDBURL.path), !fm.fileExists(atPath: copy.path) {
            try? fm.copyItem(at: device.iTunesDBURL, to: copy)
        }
    }
}
