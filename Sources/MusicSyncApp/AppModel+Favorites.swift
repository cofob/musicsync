import Foundation
import Library
import Subsonic

/// Stars and ratings. Changes show at once through the overrides, go to the server and the local library,
/// and are undone when the server refuses them.
extension AppModel {
    func isStarred(_ song: Song) -> Bool { starOverrides[song.id] ?? (song.starred != nil) }
    func isStarred(_ album: Album) -> Bool { starOverrides[album.id] ?? (album.starred != nil) }
    func isStarred(_ artist: Artist) -> Bool { starOverrides[artist.id] ?? (artist.starred != nil) }

    func toggleStar(_ song: Song) { setStar(!isStarred(song), songs: [song.id]) }
    func toggleStar(_ album: Album) { setStar(!isStarred(album), albums: [album.id]) }
    func toggleStar(_ artist: Artist) { setStar(!isStarred(artist), artists: [artist.id]) }
    /// Several songs: all become favorites, or none when all are already.
    func toggleStar(_ songs: [Song]) { setStar(!songs.allSatisfy(isStarred), songs: songs.map(\.id)) }

    private func setStar(_ star: Bool, songs: [String] = [], albums: [String] = [], artists: [String] = []) {
        let ids = songs + albums + artists
        let before = ids.map { starOverrides[$0] }
        for id in ids { starOverrides[id] = star }
        let client = client, store = store, database = library?.database
        Task {
            do {
                if star { try await client?.star(ids: songs, albumIds: albums, artistIds: artists) }
                else { try await client?.unstar(ids: songs, albumIds: albums, artistIds: artists) }
                try? await database?.setStarred(star ? Date().ISO8601Format() : nil, songIds: songs, albumIds: albums, artistIds: artists)
            } catch {
                guard store === self.store else { return }
                for (id, old) in zip(ids, before) { starOverrides[id] = old }
                report(error)
            }
        }
    }

    /// Starred items: from the local library when it is complete, else `getStarred2`.
    func favorites() async throws -> SearchResult3 {
        if usesLocalLibrary, let db = library?.database { return await db.starred() }
        return try await client?.getStarred2() ?? SearchResult3(artist: [], album: [], song: [])
    }

    /// 0 = not rated.
    func rating(_ song: Song) -> Int { ratingOverrides[song.id] ?? song.userRating ?? 0 }

    /// A server without ratings answers with an API error; the rating controls disappear then.
    func setRating(_ rating: Int, for song: Song) {
        let before = ratingOverrides[song.id]
        ratingOverrides[song.id] = rating
        let client = client, store = store, database = library?.database
        Task {
            do {
                try await client?.setRating(id: song.id, rating: rating)
                try? await database?.setRating(rating, songId: song.id)
            } catch {
                guard store === self.store else { return }
                ratingOverrides[song.id] = before
                if case .api? = error as? SubsonicError { ratingUnsupported = true }
                report(error)
            }
        }
    }
}
