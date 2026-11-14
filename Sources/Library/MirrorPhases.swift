import Foundation
import Subsonic

/// The data phases of a pass. Each one is resumable: progress lives in the database.
extension MirrorPass {
    func artists() async throws {
        let list = try await client.getArtists().flatMap { $0.artist ?? [] }
        try await database.replaceArtists(list)
        progress(total: list.count, done: list.count)
    }

    /// Pages through the whole listing. Returns false (and deletes nothing) when the library changed meanwhile.
    func albums(scanKey: String) async throws -> Bool {
        let pageSize = 500
        var cursor = force ? nil : await database.albumCursor()
        if cursor?.scan != scanKey { cursor = nil }
        let start = cursor ?? AlbumCursor(run: UUID().uuidString, offset: 0, scan: scanKey)
        if cursor == nil { try await database.beginAlbumListing(start) }
        var offset = start.offset
        var previousFirst: String?
        progress(done: offset)
        while true {
            try await throttle()
            let page = try await client.getAlbumList2(type: "alphabeticalByName", size: pageSize, offset: offset)
            // Only an empty page ends the listing; servers may cap the page size below ours.
            guard let first = page.first else { break }
            if first.id == previousFirst { throw MirrorError.incomplete("server ignores the album list offset") }
            previousFirst = first.id
            offset += page.count
            try await database.storeAlbumPage(page, run: start.run, nextOffset: offset)
            progress(done: offset)
        }
        if let after = try? await client.getScanStatus().lastScan, !scanKey.isEmpty, after != scanKey {
            warn("library changed during the album listing; starting over next time")
            return false
        }
        try await database.finishAlbumListing(run: start.run)
        return true
    }

    func tracks() async throws {
        let client = client, database = database
        try await each(await database.dirtyAlbumIDs(), what: "album") { id in
            let album = try await client.getAlbum(id: id)
            try await database.storeAlbumTracks(albumId: id, songs: album.song ?? [])
        }
    }

    func playlists() async throws {
        let client = client, database = database
        try await database.replacePlaylists(try await client.getPlaylists())
        try await each(await database.dirtyPlaylistIDs(), limit: 2, what: "playlist") { id in
            let playlist = try await client.getPlaylist(id: id)
            try await database.storePlaylistEntries(playlistId: id, songs: playlist.entry ?? [])
        }
    }

    func covers() async throws {
        let client = client, database = database
        try await each(await database.coversToFetch(), what: "cover") { id in
            do {
                let data = try await client.coverArt(id: id, size: LibraryDatabase.smallCoverSize)
                if data.isEmpty { throw SubsonicError.badResponse("empty cover") }
                try await database.storeCover(id: id, data: data)
            } catch let error as SubsonicError {
                // Remember only a server that has no usable image; other failures retry next pass.
                switch error {
                case .api, .badResponse, .badStatus(404): try await database.recordMissingCover(id: id)
                default: break
                }
                throw error
            }
        }
    }

    func lyrics() async throws {
        let client = client, database = database
        // Servers without the extension are skipped; so is any failure to ask.
        guard let extensions = try? await client.getOpenSubsonicExtensions(), extensions.contains(where: { $0.name == "songLyrics" }) else { return }
        try await each(await database.songsMissingLyrics(limit: settings.lyricsPerPass), limit: 2, what: "lyrics") { id in
            try await database.storeLyrics(songId: id, lyrics: try await client.getLyricsBySongId(id: id))
        }
    }
}
