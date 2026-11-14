import Foundation

/// State of the server's own audio output (Subsonic `jukeboxControl`), which plays the jukebox playlist.
public struct JukeboxStatus: Decodable, Equatable, Sendable {
    /// Index into the jukebox playlist; -1 or nil when nothing is current.
    public let currentIndex: Int?
    public let playing: Bool?
    /// Volume, 0...1.
    public let gain: Double?
    /// Seconds into the current song.
    public let position: Int?
}

/// The jukebox playlist with its status (`action=get`).
public struct JukeboxPlaylist: Decodable, Sendable {
    public let currentIndex: Int?
    public let playing: Bool?
    public let gain: Double?
    public let position: Int?
    public let entry: [Song]?

    public var songs: [Song] { entry ?? [] }
    public var status: JukeboxStatus { JukeboxStatus(currentIndex: currentIndex, playing: playing, gain: gain, position: position) }
}

/// A `jukeboxControl` action; each one answers with the new status.
public enum JukeboxAction: Equatable, Sendable {
    case status, start, stop, clear, shuffle
    /// Jumps to playlist entry `index`, `offset` seconds in.
    case skip(index: Int, offset: Int)
    /// Replaces the playlist.
    case set([String])
    case add([String])
    case remove(Int)
    /// 0...1.
    case setGain(Double)

    var query: [(String, String)] {
        switch self {
        case .status: [("action", "status")]
        case .start: [("action", "start")]
        case .stop: [("action", "stop")]
        case .clear: [("action", "clear")]
        case .shuffle: [("action", "shuffle")]
        case .skip(let index, let offset): [("action", "skip"), ("index", String(index)), ("offset", String(max(0, offset)))]
        case .set(let ids): [("action", "set")] + ids.map { ("id", $0) }
        case .add(let ids): [("action", "add")] + ids.map { ("id", $0) }
        case .remove(let index): [("action", "remove"), ("index", String(index))]
        case .setGain(let gain): [("action", "setGain"), ("gain", String(format: "%.2f", gain.isFinite ? min(max(gain, 0), 1) : 0))]
        }
    }
}

public extension SubsonicClient {
    /// Needs the `jukeboxRole`; servers without a jukebox answer with an error.
    func jukebox(_ action: JukeboxAction) async throws -> JukeboxStatus {
        try await fetch("jukeboxControl", "jukeboxStatus", action.query)
    }

    func jukeboxPlaylist() async throws -> JukeboxPlaylist {
        try await fetch("jukeboxControl", "jukeboxPlaylist", [("action", "get")])
    }
}
