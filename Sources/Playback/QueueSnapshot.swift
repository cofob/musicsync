import Foundation
import Support

/// The queue as saved on quit and while playing, so the next launch starts where this one stopped.
public struct QueueSnapshot<Item: Codable & Sendable>: Codable, Sendable {
    /// The server the queue belongs to (`SubsonicClient` URL and user); another server ignores it.
    public var server: String
    public var items: [Item]
    public var origins: [QueueOrigin]
    public var index: Int
    public var elapsed: TimeInterval
    public var shuffle: Bool
    public var repeatMode: String

    public init(server: String, items: [Item], origins: [QueueOrigin], index: Int, elapsed: TimeInterval,
                shuffle: Bool, repeatMode: String) {
        self.server = server
        self.items = items
        self.origins = origins
        self.index = index
        self.elapsed = elapsed
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }

    /// Nil when there is no file or it cannot be read.
    public static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.atomicWrite(JSONEncoder().encode(self), to: url)
    }

    /// Keeps only the entries `keep` accepts; the index follows the current entry, or the next one kept.
    public func filtered(_ keep: (Item) -> Bool) -> Self? {
        let kept = items.indices.filter { keep(items[$0]) }
        guard let first = kept.firstIndex(where: { $0 >= index }) ?? kept.indices.last else { return nil }
        var copy = self
        copy.items = kept.map { items[$0] }
        copy.origins = kept.map { origins.indices.contains($0) ? origins[$0] : .source }
        if kept[first] != index { copy.elapsed = 0 }
        copy.index = first
        return copy
    }
}
