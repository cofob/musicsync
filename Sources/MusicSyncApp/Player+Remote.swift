import Foundation

/// An output that plays the player's queue somewhere else, e.g. the server's jukebox. While it is the player's
/// `remote`, the mixer gets no cues, and the controls and queue edits are handed to it.
@MainActor protocol PlayerRemote: AnyObject {
    /// The queue, the current entry or play/pause changed; `restart` also jumps to `elapsed` in the current song.
    func sync(restart: Bool)
    func setGain(_ gain: Double)
}

extension Player {
    /// The remote went on to queue entry `i` by itself, e.g. at the end of a song.
    func follow(_ i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        index = i
        elapsed = 0
        trackStarted()
    }
}
