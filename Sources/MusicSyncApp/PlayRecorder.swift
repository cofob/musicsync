import Foundation
import Library
import Observation
import Recommend
import Subsonic

/// Writes what the player plays into the local history (`Library.history`), one event per track.
/// Counts only seconds actually heard: small forward steps of `elapsed`; a seek is a jump and does not count.
@MainActor
final class PlayRecorder {
    private let player: Player
    /// The library of the server that streams; read at each track start, so a server change is followed.
    private let library: () -> Library?
    private var song: Song?
    private var history: PlayHistory?
    private var startedAt = Date()
    private var played: TimeInterval = 0
    private var lastElapsed: TimeInterval = 0
    private var source = PlaySource.other
    /// Queue started by a mix or station, and songs AutoPlay added; anything else is guessed from the queue.
    private var tagged: (ids: Set<String>, source: PlaySource)?
    private var autoPlayed: Set<String> = []
    /// Called after each track start, once its event is recorded.
    var onTrackStart: () -> Void = {}

    init(player: Player, library: @escaping () -> Library?) {
        self.player = player
        self.library = library
        player.onTrackStart = { [weak self] in self?.trackStarted() }
        observeElapsed()
    }

    /// Call right before playing a queue the app made, so its plays get `source`.
    func tag(_ songs: [Song], as source: PlaySource) {
        tagged = (Set(songs.map(\.id)), source)
        autoPlayed = []
    }

    /// Songs AutoPlay appends to the current queue.
    func tagAutoPlay(_ songs: [Song]) {
        if tagged == nil || !queueIDs.isSubset(of: tagged?.ids.union(autoPlayed) ?? []) { tagged = (queueIDs, guessedSource) }
        autoPlayed.formUnion(songs.map(\.id))
    }

    private var queueIDs: Set<String> { Set(player.queue.compactMap { if case .server(let s) = $0 { s.id } else { nil } }) }

    private func trackStarted() {
        finish()
        song = nil
        // A Private Session keeps plays out of the history, as it keeps them from scrobbling.
        if case .server(let current)? = player.current, !player.privateSession {
            song = current
            history = library()?.history
            startedAt = Date()
            played = 0
            lastElapsed = 0
            source = currentSource(current.id)
        }
        onTrackStart()
    }

    private func finish() {
        guard let song, let history, played >= 1 else { return }
        let event = PlayEvent(songId: song.id, startedAt: startedAt, played: played, duration: Double(song.duration ?? 0), source: source)
        Task { try? await history.record(event) }
    }

    private func currentSource(_ id: String) -> PlaySource {
        if let tagged, queueIDs.isSubset(of: tagged.ids.union(autoPlayed)) {
            if autoPlayed.contains(id) { return .radio }
            if tagged.ids.contains(id) { return tagged.source }
        }
        return guessedSource
    }

    /// One album in the queue: an album play.
    private var guessedSource: PlaySource {
        let albums = Set(player.queue.compactMap { if case .server(let s) = $0 { s.albumId ?? "" } else { nil } })
        return albums.count == 1 ? .album : .other
    }

    private func observeElapsed() {
        withObservationTracking { _ = player.elapsed } onChange: { [weak self] in
            Task { @MainActor in self?.tick(); self?.observeElapsed() }
        }
    }

    private func tick() {
        let step = player.elapsed - lastElapsed
        if step > 0, step < 2 { played += step }
        lastElapsed = player.elapsed
    }
}
