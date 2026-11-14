import Foundation
import Playback

/// Up Next editing by queue index, the session history and the saved queue.
extension Player {
    /// Removes entries by queue index; the current one stays.
    func remove(at indexes: IndexSet) {
        line.remove(at: indexes)
        resetUpcoming()
    }

    /// Moves entries by queue index, as `Array.move(fromOffsets:toOffset:)`.
    func move(from indexes: IndexSet, to destination: Int) {
        line.move(from: indexes, to: destination)
        resetUpcoming()
    }

    /// Clear in Playing Next: the user-added and source entries go; AutoPlay stays.
    func clearUpcoming() {
        line.clearUpcoming()
        resetUpcoming()
    }

    /// AutoPlay songs go at the end, in their own section.
    func addAutoPlay(_ items: [PlayItem]) {
        guard index != nil else { return }
        line.appendAutoPlay(items)
        resetUpcoming()
    }

    /// Plays queue entry `i` now.
    func play(at i: Int) { start(at: i) }

    /// Plays a history entry again; the queue goes on after it.
    func playAgain(_ item: PlayItem) {
        guard let index else { return play([item]) }
        playNext([item])
        start(at: index + 1)
    }

    /// Songs played this session before the current one, oldest first.
    var history: [PlayItem] { current == nil ? line.history : Array(line.history.dropLast()) }

    /// The queue to save; nil when empty.
    func snapshot(server: String) -> QueueSnapshot<PlayItem>? {
        guard let index else { return nil }
        return QueueSnapshot(server: server, items: queue, origins: line.origins, index: index, elapsed: elapsed,
                             shuffle: shuffle, repeatMode: repeatMode.rawValue)
    }

    /// Loads a saved queue paused at its position: nothing plays and nothing is scrobbled until Play.
    func restore(_ saved: QueueSnapshot<PlayItem>) {
        setShuffle(saved.shuffle)
        repeatMode = RepeatMode(rawValue: saved.repeatMode) ?? .off
        transcoded = []
        line = PlayQueue(items: saved.items, origins: saved.origins, index: nil)
        start(at: saved.index, paused: true)
        if saved.elapsed > 0, current?.isLive == false { seek(to: saved.elapsed) }
    }
}
