import Subsonic

extension AppModel {
    /// One session for all lookups.
    private static let lrclib = LRCLIBClient()

    /// LRCLIB lyrics for the song in Now Playing, when Settings allows it. Replies (also "none") are kept in the library.
    func lrclibLyrics(_ song: Song) async throws -> Lyrics? {
        guard AppPreferences.shared.listening.lrclibLyrics, NetworkConsent.allowed(.lrclib), !downloads.isOffline, let artist = song.artist else { return nil }
        let database = library?.database
        let found: StructuredLyrics?
        if let stored = await database?.externalLyrics(songId: song.id, source: LRCLIBClient.source) {
            found = stored
        } else {
            found = try await Self.lrclib.lyrics(artist: artist, title: song.title, album: song.album, duration: song.duration)
            try? await database?.storeExternalLyrics(songId: song.id, source: LRCLIBClient.source, lyrics: found)
        }
        return Lyrics(lrclib: found)
    }
}

extension Lyrics {
    /// Marked with its source for the note under the lyrics.
    init?(lrclib: StructuredLyrics?) {
        guard let lrclib, var lyrics = Lyrics(lrclib) else { return nil }
        lyrics.source = LRCLIBClient.source
        self = lyrics
    }
}
