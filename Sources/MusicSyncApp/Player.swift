import AVFoundation
import AppKit
import MediaPlayer
import Observation
import Subsonic

/// One queue entry: a server track or a local file (e.g. a track read from an iPod).
enum PlayItem: Identifiable, Sendable {
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

enum RepeatMode: CaseIterable, Sendable {
    case off, all, one
    var next: RepeatMode { self == .off ? .all : self == .all ? .one : .off }
    var symbol: String { self == .one ? "repeat.1" : "repeat" }
}

@MainActor @Observable
final class Player {
    /// Suffixes streamed as-is; everything else is transcoded by the server.
    private static let rawSuffixes: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aif", "aiff"]

    private(set) var queue: [PlayItem] = []
    private(set) var index: Int?
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var artwork: NSImage?
    private(set) var errorMessage: String?
    var volume: Double = 1 { didSet { player.volume = Float(volume) } }
    private(set) var shuffle = false
    var repeatMode = RepeatMode.off { didSet { resetUpcoming() } }
    /// Playback > Private Session: no scrobbles, so plays stay out of the server's history and counts.
    var privateSession = false

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
        if let d = current?.duration { return d }
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }
    var hasNext: Bool { index.map { $0 + 1 < queue.count || repeatMode != .off } ?? false }
    var hasPrevious: Bool { index != nil }
    /// Queue entries after the current one.
    var upcoming: ArraySlice<PlayItem> { queue[min((index ?? -1) + 1, queue.count)...] }
    /// For `AVRoutePickerView`.
    var routingPlayer: AVPlayer { player }

    private struct Slot {
        let item: AVPlayerItem
        var index: Int
        let status: NSKeyValueObservation
    }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var slots: [ObjectIdentifier: Slot] = [:]
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    /// Queue indexes that failed raw and are streamed as mp3 instead.
    @ObservationIgnored private var transcoded: Set<Int> = []
    /// Tracks that failed since the last one became ready; a full queue of them stops playback.
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var scrobbled = false
    /// Item the UI shows as current; guards against handling the same item change twice.
    @ObservationIgnored private var currentItemID: ObjectIdentifier?
    /// Queue order before shuffling; nil after manual queue edits.
    @ObservationIgnored private var unshuffled: [PlayItem]?
    /// Cover id `artwork` shows; the same cover is not loaded again.
    @ObservationIgnored private var artworkID: String?
    /// Last seek: ticks far from it (stale, from before the seek) are ignored until one lands near it or the deadline passes.
    @ObservationIgnored private var seekTarget: (time: TimeInterval, deadline: Date)?

    init() {
        if ProcessInfo.processInfo.environment["MUSICSYNC_MUTE"] == "1" { volume = 0; player.volume = 0 }
        observations = [
            player.observe(\.currentItem) { [weak self] _, _ in Task { @MainActor in self?.currentItemChanged() } },
            player.observe(\.timeControlStatus) { [weak self] _, _ in Task { @MainActor in self?.statusChanged() } },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        setupRemoteCommands()
    }

    // MARK: Controls

    /// `shuffled` turns shuffle on (true) or off (false); nil keeps the current mode.
    func play(_ items: [PlayItem], startAt: Int = 0, shuffled: Bool? = nil) {
        guard !items.isEmpty else { return }
        if let shuffled { shuffle = shuffled }
        transcoded = []
        failures = 0
        if shuffle, !items.isEmpty {
            unshuffled = items
            var rest = items
            let first = shuffled == true ? rest.remove(at: Int.random(in: rest.indices)) : rest.remove(at: min(startAt, rest.count - 1))
            queue = [first] + rest.shuffled()
            start(at: 0)
        } else {
            unshuffled = nil
            queue = items
            start(at: startAt)
        }
    }

    func play(_ songs: [Song], startAt: Int = 0, shuffled: Bool? = nil) { play(songs.map(PlayItem.server), startAt: startAt, shuffled: shuffled) }

    /// Shuffles the entries after the current one, or restores their order.
    func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        guard let index, let current else { return }
        if on {
            unshuffled = queue
            var rest = queue
            rest.remove(at: index)
            queue = [current] + rest.shuffled()
            self.index = 0
        } else if let original = unshuffled {
            queue = original
            self.index = original.firstIndex { $0.id == current.id } ?? 0
            unshuffled = nil
        }
        resetUpcoming()
    }

    func playNext(_ items: [PlayItem]) {
        guard let index else { return play(items) }
        queue.insert(contentsOf: items, at: index + 1)
        queueEdited()
    }

    func addToQueue(_ items: [PlayItem]) {
        guard index != nil else { return play(items) }
        queue += items
        queueEdited()
    }

    /// `offsets` are positions in `upcoming`.
    func removeUpcoming(at offsets: IndexSet) {
        let base = (index ?? -1) + 1
        queue.remove(atOffsets: IndexSet(offsets.map { $0 + base }))
        queueEdited()
    }

    /// `offsets` and `destination` are positions in `upcoming`.
    func moveUpcoming(from offsets: IndexSet, to destination: Int) {
        let base = (index ?? -1) + 1
        queue.move(fromOffsets: IndexSet(offsets.map { $0 + base }), toOffset: destination + base)
        queueEdited()
    }

    /// Jumps to entry `offset` of `upcoming`.
    func playUpcoming(at offset: Int) { start(at: (index ?? -1) + 1 + offset) }

    func toggle() {
        if isPlaying {
            player.pause()
        } else if player.currentItem != nil {
            player.play()
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
        player.removeAllItems()
        slots = [:]
        currentItemID = nil
        queue = []
        unshuffled = nil
        index = nil
        elapsed = 0
        updateNowPlaying()
    }

    /// Uses the preloaded next item when there is one: no new stream, no queue rebuild.
    func next() {
        guard let index, hasNext else { return }
        let target = (index + 1) % queue.count
        let items = player.items()
        if items.count > 1, slots[ObjectIdentifier(items[1])]?.index == target {
            player.advanceToNextItem()
            currentItemChanged()
            player.play()
        } else {
            start(at: target)
        }
    }

    /// Restarts the track when more than 3 s in, otherwise goes to the previous one.
    func previous() {
        guard let index else { return }
        if elapsed > 3 || (index == 0 && repeatMode == .off) { seek(to: 0) } else { start(at: (index - 1 + queue.count) % queue.count) }
    }

    func seek(to time: TimeInterval) {
        elapsed = time
        seekTarget = (time, Date().addingTimeInterval(3))
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        updateNowPlaying()
    }

    // MARK: Queue handling

    private func start(at i: Int) {
        guard let i = playable(i) else { return }
        player.removeAllItems()
        slots = [:]
        index = i
        elapsed = 0
        enqueue(i)
        currentItemID = player.currentItem.map(ObjectIdentifier.init)
        enqueue(following(i))
        player.play()
        trackStarted()
    }

    /// Entry played automatically after `i`, honoring repeat.
    private func following(_ i: Int) -> Int? {
        switch repeatMode {
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

    private func queueEdited() {
        unshuffled = nil
        resetUpcoming()
    }

    /// Re-syncs the preloaded next item with `queue` after it changed.
    private func resetUpcoming() {
        transcoded = []
        for (id, slot) in slots where id != currentItemID {
            player.remove(slot.item)
            slots[id] = nil
        }
        guard let index else { return }
        if let id = currentItemID { slots[id]?.index = index }
        enqueue(following(index))
    }

    /// Appends queue entry `i` to the AVQueuePlayer (no-op if out of range or already preloaded).
    private func enqueue(_ i: Int?) {
        guard let i = i.flatMap(playable),
              !slots.contains(where: { $0.value.index == i && $0.key != currentItemID }),
              let item = makeItem(queue[i], at: i) else { return }
        let status = item.observe(\.status) { [weak self] item, _ in
            let id = ObjectIdentifier(item)
            Task { @MainActor in self?.itemStatusChanged(id) }
        }
        slots[ObjectIdentifier(item)] = Slot(item: item, index: i, status: status)
        player.insert(item, after: nil)
    }

    private func makeItem(_ entry: PlayItem, at i: Int) -> AVPlayerItem? {
        switch entry {
        case .file(let url, _, _, _):
            return AVPlayerItem(url: url)
        case .server(let song):
            if !transcoded.contains(i), let url = localFile?(song.id) { return AVPlayerItem(url: url) }
            guard let client else { return nil }
            let raw = Self.rawSuffixes.contains((song.suffix ?? "").lowercased()) && !transcoded.contains(i)
            guard raw else { return AVPlayerItem(url: client.streamURL(id: song.id, format: "mp3", maxBitRate: 320)) }
            // Raw stream URLs have no file extension; tell AVFoundation the type.
            let options = song.contentType.map { [AVURLAssetOverrideMIMETypeKey: $0] }
            return AVPlayerItem(asset: AVURLAsset(url: client.streamURL(id: song.id, format: "raw"), options: options))
        }
    }

    private func currentItemChanged() {
        guard let item = player.currentItem, ObjectIdentifier(item) != currentItemID,
              let slot = slots[ObjectIdentifier(item)] else { return }
        currentItemID = ObjectIdentifier(item)
        index = slot.index
        elapsed = 0
        let live = Set(player.items().map(ObjectIdentifier.init))
        slots = slots.filter { live.contains($0.key) }
        enqueue(following(slot.index))
        trackStarted()
    }

    private func statusChanged() {
        isPlaying = player.timeControlStatus != .paused
        updateNowPlaying()
    }

    /// Falls back to an mp3 stream when a raw stream fails; skips the track if that fails too.
    private func itemStatusChanged(_ id: ObjectIdentifier) {
        guard let slot = slots[id] else { return }
        if slot.item.status == .readyToPlay { failures = 0 }
        guard slot.item.status == .failed else { return }
        let i = slot.index
        var retry = false
        if case .server = queue[i], !transcoded.contains(i) { transcoded.insert(i); retry = true }
        if !retry { errorMessage = slot.item.error?.localizedDescription ?? "Playback failed"; failures += 1 }
        let skip = failures < queue.count
        if i == index {
            if retry { start(at: i) } else if skip { next() } else { player.pause() }
        } else {
            player.remove(slot.item)
            slots[id] = nil
            if retry { enqueue(i) } else if skip { enqueue(following(i)) }
        }
    }

    // MARK: Tracking

    private func trackStarted() {
        errorMessage = nil
        seekTarget = nil
        scrobbled = false
        startedAt = Date()
        updateNowPlaying()
        onTrackStart?()
        if case .server(let song)? = current, let client, !privateSession {
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
        if let target = seekTarget {
            guard abs(time - target.time) < 1.5 || Date() > target.deadline else { return }
            seekTarget = nil
        }
        elapsed = max(0, time)
        // Submit after 50% of the track or 4 minutes, whichever comes first.
        guard !scrobbled, !privateSession, case .server(let song)? = current, let client, duration > 0,
              elapsed >= min(duration / 2, 240) else { return }
        scrobbled = true
        let start = startedAt
        Task { try? await client.scrobble(ids: [song.id], times: [start], submission: true) }
    }

    // MARK: System integration

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = hasNext
        commands.previousTrackCommand.isEnabled = hasPrevious
        guard let item = current else { center.nowPlayingInfo = nil; center.playbackState = .stopped; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        info[MPMediaItemPropertyArtist] = item.artist
        info[MPMediaItemPropertyAlbumTitle] = item.album
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
