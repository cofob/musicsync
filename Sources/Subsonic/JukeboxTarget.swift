/// What the jukebox should play: its playlist, the current entry and whether it plays.
public struct JukeboxTarget: Equatable, Sendable {
    public var ids: [String]
    /// Index into `ids`; nil when nothing is current.
    public var index: Int?
    public var playing: Bool

    public init(ids: [String], index: Int?, playing: Bool) {
        self.ids = ids
        self.index = index
        self.playing = playing
    }

    /// The jukebox side of a play queue: `queue` holds a song id per entry, nil for entries the server cannot play
    /// (local files), which the jukebox leaves out.
    public init(queue: [String?], current: Int?, playing: Bool) {
        let index = current.flatMap { i in queue.indices.contains(i) && queue[i] != nil ? queue[..<i].count { $0 != nil } : nil }
        self.init(ids: queue.compactMap { $0 }, index: index, playing: playing)
    }

    /// Queue entry of jukebox entry `index`, the reverse of `init(queue:current:playing:)`.
    public static func queueIndex(of index: Int, in queue: [String?]) -> Int? {
        guard index >= 0 else { return nil }
        var seen = 0
        for (i, id) in queue.enumerated() where id != nil {
            if seen == index { return i }
            seen += 1
        }
        return nil
    }

    /// Actions that take the jukebox from `sent` (nil: unknown) to this target. `restart` jumps to `position`
    /// (seconds) in the current song; a new playlist goes on at `position` too, as `set` stops the current song.
    public func actions(from sent: JukeboxTarget?, position: Int, restart: Bool) -> [JukeboxAction] {
        let newList = sent?.ids != ids
        var actions: [JukeboxAction] = newList ? [.set(ids)] : []
        guard let index, ids.indices.contains(index) else {
            return actions + (sent?.playing == true && !newList ? [.stop] : [])
        }
        let moved = newList || restart || sent?.index != index
        if moved { actions.append(.skip(index: index, offset: position)) }
        if moved || sent?.playing != playing { actions.append(playing ? .start : .stop) }
        return actions
    }
}
