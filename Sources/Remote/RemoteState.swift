import Foundation

/// What the remote page shows; sent by `GET /api/state` and as `state` events.
/// Covers are `/cover/<id>` paths on this server, never server URLs (they hold credentials).
public struct RemoteState: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var artist: String?
        public var album: String?
        public var cover: String?

        public init(id: String, title: String, artist: String?, album: String?, coverArt: String?) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            cover = coverArt.map(RemoteState.coverPath)
        }
    }

    public var song: Item?
    public var elapsed: Double
    public var duration: Double
    public var playing: Bool
    public var volume: Double
    public var shuffle: Bool
    public var repeatMode: RepeatSetting
    public var starred: Bool
    /// The next songs, at most `queueLimit`.
    public var queue: [Item]
    /// Where the sound plays: the Mac's output device (an AirPlay speaker too), or the server.
    public var output = ""
    /// Nil when the server has no jukebox; true while it plays.
    public var jukebox: Bool?

    public static let queueLimit = 100

    public init(song: Item?, elapsed: Double, duration: Double, playing: Bool, volume: Double, shuffle: Bool,
                repeatMode: RepeatSetting, starred: Bool, queue: [Item]) {
        self.song = song
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.playing = playing
        self.volume = volume
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.starred = starred
        self.queue = Array(queue.prefix(Self.queueLimit))
    }

    enum CodingKeys: String, CodingKey {
        case song, elapsed, duration, playing, volume, shuffle, starred, queue, output, jukebox
        case repeatMode = "repeat"
    }

    public static func coverPath(_ id: String) -> String {
        "/cover/" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? id)
    }

    /// Sorted keys, so equal states give equal bytes.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// One row of a list or search: an artist, album, playlist, mix or song.
public struct RemoteItem: Codable, Sendable, Equatable {
    public var kind: RemoteKind
    public var id: String
    public var name: String
    public var detail: String?
    public var cover: String?

    public init(kind: RemoteKind, id: String, name: String, detail: String?, coverArt: String?) {
        self.kind = kind
        self.id = id
        self.name = name
        self.detail = detail
        cover = coverArt.map(RemoteState.coverPath)
    }
}

/// A list page or an opened artist, album, playlist or mix. `next` is the offset of the next page, if any.
public struct RemoteList: Codable, Sendable, Equatable {
    public var title: String
    public var detail: String?
    public var cover: String?
    public var items: [RemoteItem]
    public var next: Int?

    public static let pageSize = 100

    public init(title: String, detail: String? = nil, coverArt: String? = nil, items: [RemoteItem], next: Int? = nil) {
        self.title = title
        self.detail = detail
        cover = coverArt.map(RemoteState.coverPath)
        self.items = items
        self.next = next
    }

    /// Page `offset` of `all`, with `next` set when more follow.
    public static func page<T>(_ all: [T], offset: Int, title: String, item: (T) -> RemoteItem) -> RemoteList {
        let end = min(all.count, offset + pageSize)
        let items = offset < end ? all[offset..<end].map(item) : []
        return RemoteList(title: title, items: items, next: end < all.count ? end : nil)
    }
}

/// Lyrics of the song `id`; `start` (seconds) is nil for unsynced lines.
public struct RemoteLyrics: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var start: Double?
        public var text: String

        public init(start: Double?, text: String) {
            self.start = start
            self.text = text
        }
    }

    public var id: String?
    public var lines: [Line]

    public init(id: String?, lines: [Line]) {
        self.id = id
        self.lines = lines
    }
}

/// Peers the server talks to: loopback, link-local and private networks only.
public enum LocalAddress {
    /// `bytes` is a 4-byte IPv4 or 16-byte IPv6 address.
    public static func isLocal(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4:
            let (a, b) = (bytes[0], bytes[1])
            return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
        case 16:
            if bytes[..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }  // ::1
            if bytes[..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff { return isLocal(Array(bytes[12...])) }  // IPv4-mapped
            return (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) || bytes[0] & 0xfe == 0xfc  // fe80::/10, fc00::/7
        default:
            return false
        }
    }
}
