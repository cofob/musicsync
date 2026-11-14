import Foundation
import Subsonic

public enum DownloadState: String, Sendable, Equatable {
    case queued, downloading, done, failed
}

/// Why a song is kept. A song is deleted when it has none left.
public enum DownloadReason: Hashable, Sendable {
    /// Downloaded on its own.
    case song
    case album(String)
    case playlist(String)
    /// Chosen by a smart download rule; rules add and remove these on their own.
    case smart(SmartRule)

    var raw: String {
        switch self {
        case .song: "song"
        case .album(let id): "album:\(id)"
        case .playlist(let id): "playlist:\(id)"
        case .smart(let rule): "smart:\(rule.rawValue)"
        }
    }

    init?(raw: String) {
        if raw == "song" { self = .song; return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "album": self = .album(parts[1])
        case "playlist": self = .playlist(parts[1])
        case "smart": guard let rule = SmartRule(rawValue: parts[1]) else { return nil }; self = .smart(rule)
        default: return nil
        }
    }
}

/// An album or playlist kept offline. Its songs follow the server: new ones download, removed ones go.
public enum DownloadPin: Hashable, Sendable, Identifiable {
    case album(Album)
    case playlist(Playlist)

    public var reason: DownloadReason {
        switch self {
        case .album(let a): .album(a.id)
        case .playlist(let p): .playlist(p.id)
        }
    }

    public var id: String { reason.raw }

    var name: String {
        switch self {
        case .album(let a): a.name
        case .playlist(let p): p.name
        }
    }

    var coverArt: String? {
        switch self {
        case .album(let a): a.coverArt
        case .playlist(let p): p.coverArt
        }
    }

    /// Without songs: the list is in the store.
    var stripped: DownloadPin {
        switch self {
        case .album(let a): .album(a.withSongs(nil))
        case .playlist(let p): .playlist(p.withEntries(nil))
        }
    }
}

/// One song in the download store.
public struct DownloadEntry: Sendable, Equatable, Identifiable {
    public static let cancelledMessage = "Cancelled"

    public var song: Song
    public var state: DownloadState
    /// File name inside the files directory, once done.
    public var fileName: String?
    public var size: Int64
    /// Suffix of the file, e.g. "flac" or "mp3".
    public var format: String?
    public var bitRate: Int?
    public var error: String?
    public var reasons: Set<DownloadReason>

    public var id: String { song.id }
    public var isCancelled: Bool { state == .failed && error == Self.cancelledMessage }
    /// Rules that keep the song, in `SmartRule` order.
    public var smartRules: [SmartRule] { SmartRule.allCases.filter { reasons.contains(.smart($0)) } }
    /// Kept by the user (song, album or playlist download); rules never remove it.
    public var isUserKept: Bool { reasons.contains { if case .smart = $0 { false } else { true } } }
}

/// Live state of the download manager.
public struct DownloadStatus: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        /// The storage limit in the settings is reached.
        case storageLimit
        /// The disk is (almost) full.
        case diskFull
        /// The server cannot be reached.
        case offline
    }

    /// Running downloads: song id -> fraction (0...1).
    public var progress: [String: Double] = [:]
    /// Why queued songs do not start; nil when they do.
    public var blocked: Block?
    /// Songs of the current batch (since the queue was last empty) and how many of them are finished.
    public var batchTotal = 0
    public var batchDone = 0
    /// Bumped on every change of the store, so readers know to reload entries.
    public var revision = 0

    public init() {}

    /// Progress of the whole batch.
    public var fraction: Double {
        guard batchTotal > 0 else { return 1 }
        return min(1, (Double(batchDone) + progress.values.reduce(0, +)) / Double(batchTotal))
    }
}
