import Library
import Subsonic

/// Sources for the long pages. With the local library each page is a database query; before it is ready,
/// songs come from the server in its own order and albums and artists from the lists already in memory.
/// Each list comes back with its first page loaded, so the old one stays on screen until then.
extension AppModel {
    func songPages(sort: SongSort, descending: Bool, query: String) async -> PagedList<Song> {
        let list: PagedList<Song>
        if usesLocalLibrary, let db = library?.database {
            list = PagedList(total: await db.songCount(matching: query)) { offset, limit in
                await db.songs(sort: sort, descending: descending, matching: query, limit: limit, offset: offset)
            }
        } else if let client {
            // `search3` with an empty query lists the whole library (Navidrome, OpenSubsonic).
            list = PagedList(total: nil) { offset, limit in
                try await client.search3(query, artistCount: 0, albumCount: 0, songCount: limit, songOffset: offset).song
            }
        } else {
            list = PagedList(total: 0) { _, _ in [] }
        }
        await list.load(page: 0)
        return list
    }

    func albumPages(sort: AlbumSort, query: String, inMemory: () -> [Album]) async -> PagedList<Album> {
        if usesLocalLibrary, let db = library?.database {
            let list = PagedList<Album>(total: await db.albumCount(matching: query)) { offset, limit in
                await db.albums(sort: sort, matching: query, limit: limit, offset: offset)
            }
            await list.load(page: 0)
            return list
        }
        return await Self.slices(inMemory())
    }

    func artistPages(query: String) async -> PagedList<Artist> {
        if usesLocalLibrary, let db = library?.database {
            let list = PagedList<Artist>(total: await db.artistCount(matching: query)) { offset, limit in
                await db.artists(matching: query, limit: limit, offset: offset)
            }
            await list.load(page: 0)
            return list
        }
        let sorted = artists.sorted { ($0.sortName ?? $0.name).localizedStandardCompare($1.sortName ?? $1.name) == .orderedAscending }
        return await Self.slices(query.isEmpty ? sorted : sorted.filter { $0.name.localizedCaseInsensitiveContains(query) })
    }

    /// Pages over a list already in memory (iPod contents, albums before the local library is ready).
    static func slices<T: Sendable>(_ items: [T]) async -> PagedList<T> {
        let list = PagedList(total: items.count) { offset, limit in Array(items[min(offset, items.count)..<min(offset + limit, items.count)]) }
        await list.load(page: 0)
        return list
    }
}
