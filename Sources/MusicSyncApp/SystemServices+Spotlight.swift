import Integration
import Library

/// Spotlight: albums, artists and playlists of the local library. Runs after each list change from the database,
/// off the main thread; only changed items reach the index.
extension SystemServices {
    func updateSpotlight() {
        guard let spotlight else { return }
        guard indexesSpotlight else { return enqueueSpotlight { try? await spotlight.clear() } }
        guard app.usesLocalLibrary, let db = app.library?.database, let client = app.client else { return }
        let artists = app.artists, albums = app.albums, playlists = app.playlists
        let key = LibraryDatabase.serverKey(for: client.config)
        enqueueSpotlight {
            let thumbnails = await db.smallCoverURLs()
            guard !Task.isCancelled else { return }  // a newer list is waiting
            let entries = SpotlightEntry.entries(artists: artists, albums: albums, playlists: playlists, thumbnails: thumbnails)
            try? await spotlight.update(serverKey: key, entries: entries)
        }
    }

    /// Runs index work in order, in the background. A newer request cancels the one before it.
    func enqueueSpotlight(_ work: @escaping @Sendable () async -> Void) {
        let previous = spotlightTask
        previous?.cancel()
        spotlightTask = Task.detached(priority: .utility) {
            await previous?.value
            await work()
        }
    }
}
