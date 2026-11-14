import Foundation
import Subsonic

/// Choices of the browsing pages that need no database.
public enum Browse {
    /// The similar artists that are in the library, as the library has them (with their covers), without duplicates.
    /// Matched by id, else by name: servers also list artists they only know from Last.fm.
    public static func similarInLibrary(_ similar: [Artist], library: [Artist]) -> [Artist] {
        let byID = Dictionary(library.map { ($0.id, $0) }) { a, _ in a }
        let byName = Dictionary(library.map { ($0.name.lowercased(), $0) }) { a, _ in a }
        var seen = Set<String>()
        return similar.compactMap { byID[$0.id] ?? byName[$0.name.lowercased()] }.filter { seen.insert($0.id).inserted }
    }

    /// The artist's most played songs: plays in the local history first, then the server's count.
    /// Ties keep the given order (newest album first).
    public static func topSongs(_ songs: [Song], localPlays: [String: Int], limit: Int = 10) -> [Song] {
        let ranked = songs.enumerated().sorted { a, b in
            let x = (localPlays[a.element.id] ?? 0, a.element.playCount ?? 0), y = (localPlays[b.element.id] ?? 0, b.element.playCount ?? 0)
            return x == y ? a.offset < b.offset : x > y
        }
        return ranked.prefix(limit).map(\.element)
    }
}
