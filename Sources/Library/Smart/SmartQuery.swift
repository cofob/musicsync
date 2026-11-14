import Foundation

/// A bound value of a compiled smart playlist query.
enum SQLParam: SQLConvertible, Equatable {
    case text(String)
    case real(Double)

    func bind(_ s: OpaquePointer?, at i: Int32) -> Int32 {
        switch self {
        case .text(let v): v.bind(s, at: i)
        case .real(let v): v.bind(s, at: i)
        }
    }
}

/// The rules of a smart playlist as SQL over `songs s`, `albums a`, the play counts `h` and the downloaded songs.
/// Values are always bound parameters, never part of the SQL text.
struct SmartQuery: Equatable {
    var sql: String
    var params: [SQLParam]
    /// Reads `temp.smart_plays` (local play counts and last plays).
    var usesHistory: Bool
    /// Reads `temp.smart_downloads`.
    var usesDownloads: Bool

    /// Columns: id, duration (s), size (bytes), in the order the limit picks from (random: by id, shuffled later).
    init(_ playlist: SmartPlaylist, now: Date, calendar: Calendar = .current) {
        var compiler = Compiler(now: now, calendar: calendar)
        let condition = compiler.group(playlist.rules)
        let order = Self.order(playlist.limit.isOn ? playlist.limit.by : nil)
        sql = """
            SELECT s.id, COALESCE(s.duration, 0), COALESCE(json_extract(s.json, '$.size'), 0)
            FROM songs s LEFT JOIN albums a ON a.id = s.albumId LEFT JOIN temp.smart_plays h ON h.songId = s.id
            WHERE \(condition) ORDER BY \(order)
            """
        params = compiler.params
        usesHistory = compiler.usesHistory || order.contains("h.")
        usesDownloads = compiler.usesDownloads
    }

    static let plays = "MAX(s.playCount, COALESCE(h.plays, 0))"
    static let rating = "COALESCE(json_extract(s.json, '$.userRating'), 0)"

    /// Without a limit: album order, as an album list reads.
    static func order(_ by: SmartPlaylist.Order?) -> String {
        switch by {
        case nil: "s.artistKey, s.albumKey, COALESCE(s.disc, 1), COALESCE(s.track, 0), s.id"
        case .random: "s.id"
        case .mostPlayed: "\(plays) DESC, COALESCE(h.lastPlayed, 0) DESC, s.titleKey, s.id"
        case .leastPlayed: "\(plays), COALESCE(h.lastPlayed, 0), s.titleKey, s.id"
        case .recentlyAdded: "COALESCE(s.created, '') DESC, s.id"
        case .recentlyPlayed: "COALESCE(h.lastPlayed, 0) DESC, s.id"
        case .highestRated: "\(rating) DESC, \(plays) DESC, s.id"
        }
    }

    /// The SQL expression of a field. Title, artist and album use the folded keys (any case, any script).
    static func column(_ field: SmartPlaylist.Field) -> String {
        switch field {
        case .title: "s.titleKey"
        case .artist: "s.artistKey"
        case .album: "s.albumKey"
        case .albumArtist: "COALESCE(json_extract(s.json, '$.displayAlbumArtist'), json_extract(s.json, '$.albumArtist'), a.artist)"
        case .genre: "json_extract(s.json, '$.genre')"
        case .format: "s.suffix"
        case .year: "COALESCE(json_extract(s.json, '$.year'), 0)"
        case .duration: "COALESCE(s.duration, 0)"
        case .bitRate: "COALESCE(s.bitRate, 0)"
        case .playCount: plays
        case .rating: rating
        case .dateAdded: "CAST(strftime('%s', s.created) AS REAL)"
        case .lastPlayed: "h.lastPlayed"
        case .favorite: "s.starred IS NOT NULL"
        case .downloaded: "s.id IN (SELECT songId FROM temp.smart_downloads)"
        case .compilation: "COALESCE(json_extract(a.json, '$.isCompilation'), 0) = 1"
        }
    }

    private struct Compiler {
        let now: Date
        let calendar: Calendar
        var params: [SQLParam] = []
        var usesHistory = false
        var usesDownloads = false

        mutating func group(_ group: SmartPlaylist.Group) -> String {
            let parts = group.items.map { item in
                switch item {
                case .rule(let rule): "(\(self.rule(rule)))"
                case .group(let inner): "(\(self.group(inner)))"
                }
            }
            guard !parts.isEmpty else { return "1" }
            return parts.joined(separator: group.match == .all ? " AND " : " OR ")
        }

        mutating func rule(_ rule: SmartPlaylist.Rule) -> String {
            let column = SmartQuery.column(rule.field)
            if rule.field == .playCount || rule.field == .lastPlayed { usesHistory = true }
            if rule.field == .downloaded { usesDownloads = true }
            switch rule.field.kind {
            case .text: return text(column, rule)
            case .number: return number(column, rule)
            case .date: return date(column, rule)
            case .flag: return rule.op == .isFalse ? "NOT (\(column))" : column
            }
        }

        private mutating func bind(_ value: SQLParam) -> String {
            params.append(value)
            return "?"
        }

        private mutating func text(_ column: String, _ rule: SmartPlaylist.Rule) -> String {
            let folded = rule.field == .title || rule.field == .artist || rule.field == .album
            let value = Self.escape(folded ? sortKey(rule.text) : rule.text)
            let pattern = switch rule.op {
            case .contains, .notContains: "%\(value)%"
            case .startsWith: "\(value)%"
            case .endsWith: "%\(value)"
            default: value
            }
            let negated = rule.op == .notContains || rule.op == .isNot
            return "COALESCE(\(column), '') \(negated ? "NOT " : "")LIKE \(bind(.text(pattern))) ESCAPE '\\'"
        }

        private mutating func number(_ column: String, _ rule: SmartPlaylist.Rule) -> String {
            let a = Self.finite(rule.number), b = Self.finite(rule.number2)
            switch rule.op {
            case .isNot: return "\(column) <> \(bind(.real(a)))"
            case .greater: return "\(column) > \(bind(.real(a)))"
            case .less: return "\(column) < \(bind(.real(a)))"
            case .inRange: return "\(column) BETWEEN \(bind(.real(min(a, b)))) AND \(bind(.real(max(a, b))))"
            default: return "\(column) = \(bind(.real(a)))"
            }
        }

        /// Days are whole calendar days: "is" a date matches all of that day.
        private mutating func date(_ column: String, _ rule: SmartPlaylist.Rule) -> String {
            let a = Self.finite(rule.number), b = Self.finite(rule.number2)
            switch rule.op {
            case .inLast, .notInLast:
                let cutoff = now.timeIntervalSince1970 - max(0, a) * 86400
                return rule.op == .inLast ? "\(column) >= \(bind(.real(cutoff)))" : "(\(column) IS NULL OR \(column) < \(bind(.real(cutoff))))"
            case .greater: return "\(column) >= \(bind(.real(dayEnd(a))))"
            case .less: return "\(column) < \(bind(.real(dayStart(a))))"
            case .inRange: return "\(column) >= \(bind(.real(dayStart(min(a, b))))) AND \(column) < \(bind(.real(dayEnd(max(a, b)))))"
            case .isNot: return "(\(column) IS NULL OR \(column) < \(bind(.real(dayStart(a)))) OR \(column) >= \(bind(.real(dayEnd(a)))))"
            default: return "\(column) >= \(bind(.real(dayStart(a)))) AND \(column) < \(bind(.real(dayEnd(a))))"
            }
        }

        private func dayStart(_ time: Double) -> Double {
            calendar.startOfDay(for: Date(timeIntervalSince1970: time)).timeIntervalSince1970
        }

        private func dayEnd(_ time: Double) -> Double {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: time))
            return (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)).timeIntervalSince1970
        }

        private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

        /// LIKE wildcards in the user's text match only themselves.
        private static func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        }
    }
}
