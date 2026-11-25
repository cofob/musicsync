import Subsonic

extension AppModel {
    /// One session for all lookups.
    private static let videoFinder = MusicVideoFinder()

    /// The song's video: a server video, else (when allowed) one on YouTube. YouTube answers, also "none", are kept
    /// in the library. `ask` shows the consent popup (a user action); else only a saved Allow counts.
    func musicVideo(for song: Song, ask: Bool = false) async -> MusicVideo? {
        guard let client, !downloads.isOffline else { return nil }
        if serverVideos == nil { serverVideos = await client.videos() }
        if let video = MusicVideo.match(song, in: serverVideos ?? []) { return .server(id: video.id) }
        guard let artist = song.artist else { return nil }
        guard ask ? await NetworkConsent.request(.musicVideos) : NetworkConsent.allowed(.musicVideos) else { return nil }
        let database = library?.database
        if let stored = await database?.externalVideo(songId: song.id) { return stored }
        let found: MusicVideo?
        do { found = try await Self.videoFinder.video(artist: artist, title: song.title) } catch { return nil }  // asks again later
        try? await database?.storeExternalVideo(songId: song.id, video: found)
        return found
    }

    /// The video cannot play (embedding not allowed): none is kept for the song.
    func noVideo(_ song: Song) {
        let database = library?.database
        Task { try? await database?.storeExternalVideo(songId: song.id, video: nil) }
    }

    /// Shows the song's video with its own sound in Now Playing and pauses the music; tells when there is none.
    func openVideo(for song: Song) async {
        guard let video = await musicVideo(for: song, ask: true) else { noVideoAlert = true; return }
        player.pause()
        shownVideo = video
        showNowPlaying = true
    }
}
