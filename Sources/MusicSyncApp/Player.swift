import SwiftUI
import MediaPlayer
import Observation
import Playback
import Subsonic

/// One queue entry: a server track or a local file (e.g. a track read from an iPod).
enum PlayItem: Identifiable, Codable, Sendable {
    case server(Song)
    case file(URL, title: String, artist: String?, album: String?)

    var id: String {
        switch self {
        case .server(let song): song.id
        case .file(let url, _, _, _): url.absoluteString
        }
    }
    var title: String {
        switch self {
        case .server(let song): song.title
        case .file(_, let title, _, _): title
        }
    }
    var artist: String? {
        switch self {
        case .server(let song): song.artistName
        case .file(_, _, let artist, _): artist
        }
    }
    var album: String? {
        switch self {
        case .server(let song): song.album
        case .file(_, _, _, let album): album
        }
    }
    var duration: TimeInterval? {
        if case .server(let song) = self, let d = song.duration { return TimeInterval(d) }
        return nil
    }
    /// Server cover art id, if any.
    var coverArt: String? {
        if case .server(let song) = self { return song.coverArt }
        return nil
    }
}

private struct ImageBox: @unchecked Sendable { let image: NSImage }

enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one
    var next: RepeatMode { self == .off ? .all : self == .all ? .one : .off }
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

@MainActor @Observable
final class Player {
    /// Entries, their sections and the history (`Player+Queue`).
    var line = PlayQueue<PlayItem>()
    var queue: [PlayItem] { line.items }
    var index: Int? { get { line.index } set { line.index = newValue } }
    var isPlaying = false
    var elapsed: TimeInterval = 0
    private(set) var artwork: NSImage? { didSet { CoverAccent.shared.image = artwork } }
    private(set) var errorMessage: String?
    var volume: Double = 1 { didSet { if let remote { remote.setGain(volume) } else { mixer.volume = Float(volume) } } }
    private(set) var shuffle = false
    var repeatMode = RepeatMode.off { didSet { resetUpcoming() } }
    /// Playback > Private Session: no scrobbles, so plays stay out of the server's history and counts.
    var privateSession = false
    /// Settings > Playback; saved on every change.
    var settings = PlaybackSettings.load() { didSet { settingsChanged(from: oldValue) } }
    /// Window > Equalizer; saved on every change.
    var equalizer = EqualizerSettings.load() { didSet { equalizerChanged(from: oldValue) } }
    /// Visualizers on screen; they need the audio tap.
    @ObservationIgnored var visualizers = 0 { didSet { tapChanged(); analyzeUpcoming() } }
    /// The current song's analysis, once made for a visualizer that follows its parts (`Player+AutoMix`).
    var analysis: SongAnalysis?
    /// Where the parts of the current song start.
    var sections: [TimeInterval]? { analysis?.sections }
    /// Pauses at its deadline, or stops at the end of the current song.
    var sleepTimer: SleepTimer? { didSet { sleepTimerChanged() } }
    /// The server has the OpenSubsonic `transcodeOffset` extension.
    var supportsTranscodeOffset = false
    /// Low Data Mode or a hotspot: streams use the metered quality (`Player+Network`).
    var isMetered = false { didSet { if isMetered != oldValue { resetUpcoming() } } }
    /// An AutoMix transition is running: two songs play. Not set for a plain crossfade.
    var isMixing = false
    /// Plays the queue somewhere else (the server's jukebox); the mixer stays silent meanwhile.
    var remote: PlayerRemote?

    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored var covers: CoverArtCache?
    /// Downloaded file of a server song; played instead of the stream.
    @ObservationIgnored var localFile: ((String) -> URL?)?
    /// False for entries that cannot play now (offline and not downloaded); they are skipped.
    @ObservationIgnored var canPlay: ((PlayItem) -> Bool)?
    /// Called when a track starts, also when it repeats; the play history and AutoPlay listen here.
    @ObservationIgnored var onTrackStart: (() -> Void)?

    var current: PlayItem? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var duration: TimeInterval {
        current?.isLive == true ? 0 : current?.duration ?? mixer.duration ?? 0
    }
    var hasNext: Bool { index.map { $0 + 1 < queue.count || repeatMode != .off } ?? false }
    var hasPrevious: Bool { index != nil }
    /// Queue entries after the current one.
    var upcoming: ArraySlice<PlayItem> { queue[min((index ?? -1) + 1, queue.count)...] }

    /// Plays the current and the next song: gapless or crossfaded (`Playback/Mixer`).
    @ObservationIgnored let mixer = Mixer()
    /// Queue index of the song the mixer holds as next.
    @ObservationIgnored var nextIndex: Int?
    /// Song analyses for AutoMix (`Player+AutoMix`).
    @ObservationIgnored let analyses = AnalysisQueue()
    /// Queue indexes that failed raw and are streamed as mp3 instead.
    @ObservationIgnored var transcoded: Set<Int> = []
    /// Tracks that failed since the last one became ready; a full queue of them stops playback.
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var scrobbled = false
    /// Cover id `artwork` shows; the same cover is not loaded again.
    @ObservationIgnored private var artworkID: String?
    /// Last seek: ticks far from it (stale, from before the seek) are ignored until one lands near it or the deadline passes.
    @ObservationIgnored private var seekTarget: (time: TimeInterval, deadline: Date)?
    @ObservationIgnored var sleepTask: Task<Void, Never>?

    init() {
        if ProcessInfo.processInfo.environment["MUSICSYNC_MUTE"] == "1" { volume = 0; mixer.volume = 0 }
        applySpeed()
        tapChanged()
        mixer.onEvent = { [weak self] in self?.mixerEvent($0) }
        mixer.onTime = { [weak self] in self?.tick($0) }
        setupRemoteCommands()
        watchNetwork()
    }

    // MARK: Controls

    /// `shuffled` turns shuffle on (true) or off (false); nil keeps the current mode.
    func play(_ items: [PlayItem], startAt: Int = 0, shuffled: Bool? = nil) {
        guard !items.isEmpty else { return }
        if let shuffled { shuffle = shuffled }
        transcoded = []
        failures = 0
        start(at: line.replace(items, startAt: startAt, shuffle: shuffle, randomStart: shuffled == true))
    }

    func play(_ songs: [Song], startAt: Int = 0, shuffled: Bool? = nil) { play(songs.map(PlayItem.server), startAt: startAt, shuffled: shuffled) }

    /// Shuffles the entries after the current one, or restores their order.
    func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        line.setShuffle(on)
        resetUpcoming()
    }

    func playNext(_ items: [PlayItem]) {
        guard index != nil else { return play(items) }
        line.insertNext(items)
        resetUpcoming()
    }

    func addToQueue(_ items: [PlayItem]) {
        guard index != nil else { return play(items) }
        line.insertLast(items)
        resetUpcoming()
    }

    /// `offsets` are positions in `upcoming`.
    func removeUpcoming(at offsets: IndexSet) {
        let base = (index ?? -1) + 1
        remove(at: IndexSet(offsets.map { $0 + base }))
    }

    /// `offsets` and `destination` are positions in `upcoming`.
    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        let base = (index ?? -1) + 1
        move(from: IndexSet(offsets.map { $0 + base }), to: destination + base)
    }

    /// Jumps to entry `offset` of `upcoming`.
    func playUpcoming(at offset: Int) { start(at: (index ?? -1) + 1 + offset) }

    func toggle() {
        if let remote {
            if current != nil { isPlaying.toggle(); remote.sync(restart: false) }
        } else if isPlaying {
            mixer.pause()
        } else if mixer.hasCurrent {
            mixer.resume()
        } else if !queue.isEmpty {
            start(at: index ?? 0)
        }
    }

    /// Clears the queue when it holds local files under `root`, so that volume can be ejected.
    func stopPlayback(under root: URL) {
        let held = queue.contains { if case .file(let url, _, _, _) = $0 { url.path.hasPrefix(root.path + "/") } else { false } }
        if held { stop() }
    }

    /// Stops and clears the queue.
    func stop() {
        mixer.stop()
        isMixing = false
        nextIndex = nil
        line = PlayQueue()
        elapsed = 0
        updateNowPlaying()
    }

    /// Uses the preloaded next item when there is one: no new stream, no queue rebuild.
    func next() {
        guard let index, hasNext else { return }
        let target = (index + 1) % queue.count
        if nextIndex == target, mixer.skipToNext() { mixer.resume() } else { start(at: target) }
    }

    /// Restarts the track when more than 3 s in, otherwise goes to the previous one.
    func previous() {
        guard let index else { return }
        if elapsed > 3 || (index == 0 && repeatMode == .off) { seek(to: 0) } else { start(at: (index - 1 + queue.count) % queue.count) }
    }

    func seek(to time: TimeInterval) {
        // Saved, remote and server positions may be junk; `Int(time)` traps on NaN and huge values.
        let time = time.isFinite ? min(max(0, time), duration > 0 ? duration : 1e7) : 0
        elapsed = time
        seekTarget = (time, Date().addingTimeInterval(3))
        mixer.seek(to: time)
        remote?.sync(restart: true)
        updateNowPlaying()
    }

    // MARK: Queue handling

    /// When nothing from `i` on can play and no entry is current (a new list while offline), the old song stops too.
    func start(at i: Int, paused: Bool = false) {
        guard let i = playable(i) else {
            if index == nil { mixer.stop(); nextIndex = nil; elapsed = 0; updateNowPlaying() }
            return
        }
        index = i
        elapsed = 0
        if let cue = cue(at: i) { mixer.play(cue, paused: paused) } else { mixer.stop() }
        if let remote { isPlaying = !paused; remote.sync(restart: true) }
        preload(following(i))
        trackStarted()
    }

    /// Entry played automatically after `i`, honoring repeat.
    private func following(_ i: Int) -> Int? {
        if sleepTimer == .endOfSong { return nil }
        return switch repeatMode {
        case .one: i
        case .all: queue.isEmpty ? nil : (i + 1) % queue.count
        case .off: i + 1
        }
    }

    /// First entry from `i` on that can play now, wrapping around with repeat all.
    private func playable(_ i: Int) -> Int? {
        guard queue.indices.contains(i) else { return nil }
        let order = repeatMode == .all ? (0..<queue.count).map { (i + $0) % queue.count } : Array(i..<queue.count)
        return order.first { canPlay?(queue[$0]) ?? true }
    }

    /// Re-syncs the preloaded next song with `queue` after it changed.
    func resetUpcoming() {
        remote?.sync(restart: false)
        transcoded = []
        guard let index else { return }
        preload(following(index))
    }

    /// Hands queue entry `i` to the mixer as the next song, with its crossfade; nil clears it.
    /// A live stream is never preloaded: it would hold a connection open; `ended()` starts it.
    private func preload(_ i: Int?) {
        let i = i.flatMap(playable).flatMap { queue[$0].isLive ? nil : $0 }
        let cue = i.flatMap(cue(at:))
        nextIndex = cue == nil ? nil : i
        mixer.setNext(cue, transition: i.flatMap(transition(to:)))
        analyzeUpcoming()
    }

    private func mixerEvent(_ event: Mixer.Event) {
        switch event {
        case .advanced(let skipped): advanced(skipped: skipped)
        case .ready: failures = 0
        case .failed(let current, let message): failed(current: current, message: message)
        case .ended: ended()
        case .playing(let playing): if remote == nil { isPlaying = playing; updateNowPlaying() }
        }
    }

    /// The preloaded next song became the audible one.
    private func advanced(skipped: Bool) {
        guard let i = nextIndex else { return }
        let message = skipped ? nil : silentEndMessage
        index = i
        nextIndex = nil
        elapsed = 0
        preload(following(i))
        trackStarted()
        errorMessage = message
    }

    /// The current song played to its end with nothing preloaded after it. After the sleep timer stopped it,
    /// the next song waits paused; a live stream, which is never preloaded, starts now.
    private func ended() {
        guard let index else { return }
        let message = silentEndMessage
        if sleepTimer == .endOfSong {
            sleepTimer = nil
            if let i = following(index) { start(at: i, paused: true) }
        } else if let i = following(index).flatMap(playable), queue[i].isLive {
            start(at: i)
        }
        if let message { errorMessage = message }
    }

    /// Set when the current song ended without being heard: the server sent no audio, e.g. an error page.
    var silentEndMessage: String? {
        guard elapsed < 1, (current?.duration ?? 0) > 5, let title = current?.title else { return nil }
        return "“\(title)” could not be played: the server sent no audio."
    }

    /// Falls back to an mp3 stream when the first choice fails; skips the track if that fails too.
    private func failed(current: Bool, message: String?) {
        guard let i = current ? index : nextIndex, queue.indices.contains(i) else { return }
        var retry = false
        if case .server = queue[i], !transcoded.contains(i) { transcoded.insert(i); retry = true }
        if !retry { errorMessage = message ?? "Playback failed"; failures += 1 }
        let skip = failures < queue.count
        if current {
            if retry { start(at: i) } else if skip { next(); errorMessage = message ?? "Playback failed" } else { mixer.pause() }
        } else {
            nextIndex = nil
            if retry { preload(i) } else if skip { preload(following(i)) }
        }
    }

    // MARK: Tracking

    func trackStarted() {
        errorMessage = nil
        seekTarget = nil
        scrobbled = false
        startedAt = Date()
        line.recordStart()
        updateNowPlaying()
        onTrackStart?()
        // A song loaded paused (after the sleep timer) is not playing yet.
        if case .server(let song)? = current, let client, sendsScrobbles, isPlaying {
            Task { try? await client.scrobble(ids: [song.id], submission: false) }
        }
        let cover = current?.coverArt
        guard cover != artworkID else { return prefetchNextCover() }
        artworkID = cover
        artwork = cover.flatMap { covers?.cached(id: $0, size: 600) }
        guard let cover, let covers, artwork == nil else { return prefetchNextCover() }
        Task {
            let image = await covers.image(id: cover, size: 600)
            if artworkID == cover, let image { artwork = image; updateNowPlaying() }
            prefetchNextCover()
        }
    }

    /// Loads the next entry's cover into memory, so `next()` shows it at once.
    private func prefetchNextCover() {
        guard let i = index.flatMap(following), queue.indices.contains(i), let cover = queue[i].coverArt,
              let covers, covers.cached(id: cover, size: 600) == nil else { return }
        Task { _ = await covers.image(id: cover, size: 600) }
    }

    private func tick(_ time: TimeInterval) {
        guard time.isFinite else { return }
        let mixing = settings.transitions == .autoMix && mixer.isFading
        if mixing != isMixing { isMixing = mixing }
        if let target = seekTarget {
            guard abs(time - target.time) < 1.5 || Date() > target.deadline else { return }
            seekTarget = nil
        }
        elapsed = max(0, time)
        // Submit after 50% of the track or 4 minutes, whichever comes first.
        guard !scrobbled, sendsScrobbles, case .server(let song)? = current, let client, duration > 0,
              elapsed >= min(duration / 2, 240) else { return }
        scrobbled = true
        let start = startedAt
        Task { try? await client.scrobble(ids: [song.id], times: [start], submission: true) }
    }

    // MARK: System integration

    func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = hasNext
        commands.previousTrackCommand.isEnabled = hasPrevious
        guard let item = current else { center.nowPlayingInfo = nil; center.playbackState = .stopped; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? settings.speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: settings.speed,
        ]
        info[MPMediaItemPropertyArtist] = item.artist
        info[MPMediaItemPropertyAlbumTitle] = item.album
        info[MPNowPlayingInfoPropertyIsLiveStream] = item.isLive
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.mediaArtwork(ImageBox(image: artwork)) }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    /// Nonisolated: MediaPlayer calls the image handler on its own queue, so it must not inherit main-actor isolation.
    private nonisolated static func mediaArtwork(_ box: ImageBox) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: box.image.size) { _ in box.image }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.toggle() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.toggle() } }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
    }
}
