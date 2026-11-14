import Foundation

/// Size limit of a cache folder. Call off the main thread: it walks the folder.
public enum DiskCache {
    /// Bytes of all files under `directory`.
    public static func size(of directory: URL) -> Int64 {
        files(in: directory).reduce(0) { $0 + $1.size }
    }

    /// Deletes the least recently changed files until the folder holds at most `limit` bytes.
    @discardableResult
    public static func trim(_ directory: URL, to limit: Int64) -> Int {
        var list = files(in: directory)
        var total = list.reduce(0) { $0 + $1.size }
        guard total > limit else { return 0 }
        list.sort { $0.date < $1.date }
        var removed = 0
        for file in list where total > limit {
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            removed += 1
        }
        return removed
    }

    /// Deletes everything inside `directory`; the folder stays.
    public static func clear(_ directory: URL) {
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func files(in directory: URL) -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return walker.compactMap { item in
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}
