import Foundation
import Recommend
import Subsonic

/// Smart playlist evaluation. The local play counts and the downloaded songs live in other files, so they go into
/// temporary tables of this connection before the query runs.
extension LibraryDatabase {
    /// The songs that match `playlist`, after its limit. `plays` and `downloaded` are read only when a rule needs them.
    public func smartMatches(_ playlist: SmartPlaylist, plays: [String: SongStats], downloaded: Set<String>,
                             now: Date = Date()) -> SmartPlaylist.Matches {
        read(SmartPlaylist.Matches()) { try Self.smartMatches($0, playlist, plays: plays, downloaded: downloaded, now: now) }
    }

    static func smartMatches(_ db: SQLiteConnection, _ playlist: SmartPlaylist, plays: [String: SongStats], downloaded: Set<String>,
                             now: Date) throws -> SmartPlaylist.Matches {
        let query = SmartQuery(playlist, now: now)
        try db.exec("CREATE TEMP TABLE IF NOT EXISTS smart_plays(songId TEXT PRIMARY KEY, plays INTEGER NOT NULL, lastPlayed REAL) WITHOUT ROWID")
        try db.exec("CREATE TEMP TABLE IF NOT EXISTS smart_downloads(songId TEXT PRIMARY KEY) WITHOUT ROWID")
        if query.usesHistory {
            try fill(db, "smart_plays", plays.map { id, stats -> [any SQLConvertible] in [id, stats.plays, stats.lastPlayed?.timeIntervalSince1970] })
        }
        if query.usesDownloads { try fill(db, "smart_downloads", downloaded.map { id -> [any SQLConvertible] in [id] }) }
        let rows = try db.rows(query.sql, query.params) { (id: $0.text(0) ?? "", duration: $0.int(1), size: Int64($0.int(2))) }
        return limit(rows, playlist)
    }

    /// Applies the limit to rows in their query order (shuffled first for a random pick).
    static func limit(_ rows: [(id: String, duration: Int, size: Int64)], _ playlist: SmartPlaylist) -> SmartPlaylist.Matches {
        let limit = playlist.limit
        var rows = rows
        if limit.isOn && limit.by == .random {
            var random = SeededRandom(seed: playlist.seed)
            rows.shuffle(using: &random)
        }
        var out = SmartPlaylist.Matches()
        let amount = max(0, limit.amount)
        for row in rows {
            if limit.isOn {
                let full = switch limit.unit {
                case .songs: Double(out.ids.count + 1) > amount
                case .minutes: Double(out.duration + row.duration) > amount * 60
                case .hours: Double(out.duration + row.duration) > amount * 3600
                case .megabytes: Double(out.size + row.size) > amount * 1_000_000
                case .gigabytes: Double(out.size + row.size) > amount * 1_000_000_000
                }
                if full { break }
            }
            out.ids.append(row.id)
            out.duration += row.duration
            out.size += row.size
        }
        return out
    }

    private static func fill(_ db: SQLiteConnection, _ table: String, _ rows: [[any SQLConvertible]]) throws {
        try db.transaction {
            try db.exec("DELETE FROM temp.\(table)")
            guard let width = rows.first?.count else { return }
            let insert = try db.prepare("INSERT OR REPLACE INTO temp.\(table) VALUES(\(Array(repeating: "?", count: width).joined(separator: ", ")))")
            for row in rows { try insert.run(row) }
        }
    }
}

extension Library {
    /// The matches of `playlist`, with the local listening history; frozen songs while live updating is off.
    public func smartMatches(_ playlist: SmartPlaylist, downloaded: Set<String>, now: Date = Date()) async -> SmartPlaylist.Matches {
        if !playlist.liveUpdating, let frozen = playlist.frozen {
            let songs = await database.songs(ids: frozen)
            return SmartPlaylist.Matches(ids: songs.map(\.id), duration: songs.reduce(0) { $0 + ($1.duration ?? 0) },
                                         size: songs.reduce(0) { $0 + Int64($1.size ?? 0) })
        }
        let plays = SmartQuery(playlist, now: now).usesHistory ? await history.stats() : [:]
        return await database.smartMatches(playlist, plays: plays, downloaded: downloaded, now: now)
    }

    /// The songs of `playlist` in playlist order.
    public func smartSongs(_ playlist: SmartPlaylist, downloaded: Set<String>, now: Date = Date()) async -> [Song] {
        await database.songs(ids: smartMatches(playlist, downloaded: downloaded, now: now).ids)
    }
}
