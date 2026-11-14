import Foundation

/// A playlist kept on this Mac whose songs are the library songs that match its rules, as in iTunes and Apple Music.
/// It is evaluated against the local library mirror only; nothing goes to the server.
public struct SmartPlaylist: Codable, Hashable, Sendable, Identifiable {
    public static let idPrefix = "smart:"

    /// Starts with `idPrefix`, so it never collides with a server playlist id.
    public var id: String
    public var name: String
    public var rules: Group
    public var limit: Limit
    /// Off: the songs stay as they were when the playlist was last saved (`frozen`).
    public var liveUpdating: Bool
    public var frozen: [String]?
    /// Keeps a random selection the same between evaluations.
    public var seed: UInt64

    public init(name: String = "Untitled Smart Playlist") {
        id = Self.idPrefix + UUID().uuidString
        self.name = name
        rules = Group(match: .all, items: [.rule(Rule(field: .artist, op: .contains))])
        limit = Limit()
        liveUpdating = true
        seed = UInt64.random(in: 1...(1 << 53))  // exact in any JSON reader
    }

    public static func isSmart(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// A copy with a new id and name, for "Duplicate".
    public func duplicated() -> SmartPlaylist {
        var copy = self
        copy.id = Self.idPrefix + UUID().uuidString
        copy.name = "\(name) copy"
        return copy
    }

    /// All rules (`all`) or at least one (`any`) must match.
    public enum Match: String, Codable, CaseIterable, Sendable { case all, any }

    /// A list of rules, and at the top level also nested groups (one level in the editor).
    public struct Group: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var match: Match
        public var items: [Item]

        public init(match: Match = .all, items: [Item]) {
            self.match = match
            self.items = items
        }
    }

    public enum Item: Codable, Hashable, Sendable, Identifiable {
        case rule(Rule)
        case group(Group)

        public var id: UUID {
            switch self {
            case .rule(let rule): rule.id
            case .group(let group): group.id
            }
        }
    }

    /// One condition. Text fields use `text`; numbers `number` (and `number2` as the end of a range);
    /// dates hold seconds since 1970 in `number`, or a count of days for `inLast` and `notInLast`.
    public struct Rule: Codable, Hashable, Sendable, Identifiable {
        public var id = UUID()
        public var field: Field
        public var op: Operator
        public var text = ""
        public var number: Double = 0
        public var number2: Double = 0

        public init(field: Field, op: Operator, text: String = "", number: Double = 0, number2: Double = 0) {
            self.field = field
            self.op = op
            self.text = text
            self.number = number
            self.number2 = number2
        }

        /// Changes the field; the operator and value change too when the old ones do not fit it.
        public mutating func setField(_ new: Field) {
            let kind = field.kind
            field = new
            guard new.kind != kind else { return }
            op = new.kind.operators[0]
            text = ""
            number = new.kind == .date ? Date().timeIntervalSince1970.rounded(.down) : 0
            number2 = number
            if op == .inLast { number = 30 }
        }
    }

    public enum Field: String, Codable, CaseIterable, Sendable {
        case title, artist, album, albumArtist, genre, format
        case year, duration, bitRate, playCount, rating
        case dateAdded, lastPlayed
        case favorite, downloaded, compilation

        public var kind: Kind {
            switch self {
            case .title, .artist, .album, .albumArtist, .genre, .format: .text
            case .year, .duration, .bitRate, .playCount, .rating: .number
            case .dateAdded, .lastPlayed: .date
            case .favorite, .downloaded, .compilation: .flag
            }
        }
    }

    public enum Kind: Sendable {
        case text, number, date, flag

        public var operators: [Operator] {
            switch self {
            case .text: [.contains, .notContains, .is, .isNot, .startsWith, .endsWith]
            case .number: [.is, .isNot, .greater, .less, .inRange]
            case .date: [.inLast, .notInLast, .is, .isNot, .greater, .less, .inRange]
            case .flag: [.isTrue, .isFalse]
            }
        }
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case contains, notContains, `is`, isNot, startsWith, endsWith
        /// For dates: after and before.
        case greater, less, inRange
        case inLast, notInLast
        case isTrue, isFalse
    }

    /// At most `amount` songs, minutes, hours or gigabytes, picked by `by`.
    public struct Limit: Codable, Hashable, Sendable {
        public var isOn = false
        public var amount: Double = 25
        public var unit: Unit = .songs
        public var by: Order = .random

        public init() {}

        public enum Unit: String, Codable, CaseIterable, Sendable { case songs, minutes, hours, megabytes, gigabytes }
    }

    public enum Order: String, Codable, CaseIterable, Sendable {
        case random, mostPlayed, leastPlayed, recentlyAdded, recentlyPlayed, highestRated
    }

    /// The matching songs (after the limit), in playlist order, with their total length and size.
    public struct Matches: Sendable, Equatable {
        public var ids: [String] = []
        /// Seconds.
        public var duration = 0
        public var size: Int64 = 0

        public init(ids: [String] = [], duration: Int = 0, size: Int64 = 0) {
            self.ids = ids
            self.duration = duration
            self.size = size
        }
    }
}

/// The saved smart playlists. Unreadable entries (e.g. from a newer version) are skipped, not the whole list.
public struct SmartPlaylistList: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = Self.currentVersion
    public var playlists: [SmartPlaylist] = []

    public init(playlists: [SmartPlaylist] = []) { self.playlists = playlists }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        playlists = ((try? c.decodeIfPresent([Lossy].self, forKey: .playlists)) ?? []).compactMap(\.value)
    }

    private struct Lossy: Decodable {
        let value: SmartPlaylist?
        init(from decoder: Decoder) throws { value = try? SmartPlaylist(from: decoder) }
    }
}
