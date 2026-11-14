import Foundation
import Subsonic
import Support

/// Least-recently-used accounting of the playback cache. Pure, so it is tested without files.
struct CacheIndex: Codable, Equatable {
    struct Item: Codable, Equatable {
        var fileName: String
        var size: Int64
        /// Last play or write, seconds since 1970.
        var used: Double
    }

    var items: [String: Item] = [:]

    var bytes: Int64 { items.values.reduce(0) { $0 + $1.size } }

    /// Adds or replaces `id`, then evicts until `limit` holds. Returns the removed items (a replaced file too).
    mutating func insert(_ id: String, _ item: Item, limit: Int64) -> [Item] {
        let replaced = items.updateValue(item, forKey: id).map { $0.fileName == item.fileName ? [] : [$0] } ?? []
        return replaced + trim(to: limit)
    }

    mutating func touch(_ id: String, at time: Double) { items[id]?.used = time }

    /// Removes the least recently used items until at most `limit` bytes are left.
    mutating func trim(to limit: Int64) -> [Item] {
        var total = bytes, gone: [Item] = []
        for (id, item) in items.sorted(by: { ($0.value.used, $0.key) < ($1.value.used, $1.key) }) where total > limit {
            items[id] = nil
            total -= item.size
            gone.append(item)
        }
        return gone
    }
}

/// Songs streamed in full, kept for offline play and to save bandwidth. Separate from downloads: it has its own
/// size limit and drops the least recently played songs first. The index is a small JSON file next to the files.
public actor PlaybackCache {
    public nonisolated let directory: URL
    private var index = CacheIndex()
    private var limit: Int64
    private var loaded = false

    public init(serverKey: String, directory: URL? = nil, limitGB: Double) {
        self.directory = directory ?? Paths.caches("playback", LibraryDatabase.hash(serverKey))
        limit = SmartSettings.bytes(limitGB)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// Cached files by song id.
    public func files() -> [String: URL] {
        load()
        return index.items.mapValues { directory.appendingPathComponent($0.fileName) }
    }

    public func usedBytes() -> Int64 {
        load()
        return index.bytes
    }

    public func setLimit(gb: Double) {
        load()
        limit = SmartSettings.bytes(gb)
        remove(index.trim(to: limit))
    }

    /// Marks a cached song as played now, so it is kept longest.
    public func touch(_ id: String) {
        load()
        guard index.items[id] != nil else { return }
        index.touch(id, at: Date().timeIntervalSince1970)
        save()
    }

    public func clear() {
        load()
        remove(Array(index.items.values))
        index = CacheIndex()
        save()
    }

    /// Downloads `song` as the player streams it (`format` "raw" for the original file) and keeps it.
    /// Skipped when the cache is off, the song is already cached, or the disk is too full. Returns the file.
    public func store(_ song: Song, format: String, maxBitRate: Int?, client: SubsonicClient) async throws -> URL? {
        load()
        if let item = index.items[song.id] { return directory.appendingPathComponent(item.fileName) }
        let estimate = Int64(song.size ?? (song.duration ?? 300) * 40_000)
        guard limit > 0, estimate <= limit, let free = freeDisk(), free > estimate + SmartPlanner.reserveBytes else { return nil }
        let tmp = try await client.download(id: song.id, format: format, maxBitRate: maxBitRate)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Task.checkCancellation()
        let suffix = format == "raw" ? (song.suffix ?? "audio") : format
        let name = "\(LibraryDatabase.hash(song.id)).\(suffix)"
        let dest = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        remove(index.insert(song.id, .init(fileName: name, size: size, used: Date().timeIntervalSince1970), limit: limit))
        save()
        return index.items[song.id] == nil ? nil : dest
    }

    private func remove(_ items: [CacheIndex.Item]) {
        for item in items { try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.fileName)) }
        if !items.isEmpty { save() }
    }

    /// Reads the index once; entries whose file is gone are dropped.
    private func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL), var saved = try? JSONDecoder().decode(CacheIndex.self, from: data) else { return }
        saved.items = saved.items.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path) }
        index = saved
    }

    private func save() {
        if let data = try? JSONEncoder().encode(index) { try? FileManager.default.atomicWrite(data, to: indexURL) }
    }

    private func freeDisk() -> Int64? {
        (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}
