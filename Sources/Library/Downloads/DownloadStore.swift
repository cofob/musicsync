import Foundation
import Subsonic

/// Downloaded songs of one server and the reasons they are kept. Unlike the library mirror this is user data,
/// so the file is never replaced. Reads return empty values when the file cannot be used; writes throw.
public actor DownloadStore {
    public nonisolated let fileURL: URL
    private var connection: SQLiteConnection?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private static let schema = [
        """
        CREATE TABLE songs(
          id TEXT PRIMARY KEY, state TEXT NOT NULL, fileName TEXT, size INTEGER NOT NULL DEFAULT 0, format TEXT,
          bitRate INTEGER, error TEXT, json TEXT NOT NULL, lyrics TEXT, addedAt REAL NOT NULL)
        """,
        """
        CREATE TABLE reasons(
          songId TEXT NOT NULL REFERENCES songs(id) ON DELETE CASCADE, reason TEXT NOT NULL,
          PRIMARY KEY(songId, reason)) WITHOUT ROWID
        """,
        "CREATE INDEX reasons_reason ON reasons(reason)",
        // songIDs: JSON list in the album or playlist order, with repeats.
        "CREATE TABLE pins(reason TEXT PRIMARY KEY, json TEXT NOT NULL, songIDs TEXT NOT NULL, addedAt REAL NOT NULL) WITHOUT ROWID",
    ]

    private func db() throws -> SQLiteConnection {
        if let connection { return connection }
        let db = try SQLiteConnection(path: fileURL.path)
        try db.exec("PRAGMA journal_mode = WAL")
        try db.exec("PRAGMA foreign_keys = ON")
        if try db.scalar("PRAGMA user_version") == 0 {
            try db.transaction {
                for sql in Self.schema { try db.exec(sql) }
                try db.exec("PRAGMA user_version = 1")
            }
        }
        connection = db
        return db
    }

    private func write<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        let db = try db()
        return try db.transaction { try body(db) }
    }

    private func read<T>(_ fallback: T, _ body: (SQLiteConnection) throws -> T) -> T {
        do { return try body(try db()) } catch {
            libraryLog.warning("downloads read failed: \(String(describing: error))")
            return fallback
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: Reasons

    /// Adds `reason` to the songs; new songs are queued. Known songs get the fresh song data.
    public func add(_ songs: [Song], reason: DownloadReason) throws {
        let rows = try songs.map { ($0.id, try json($0)) }
        try write { db in try insert(db, rows, reason: reason) }
    }

    private func insert(_ db: SQLiteConnection, _ rows: [(String, String)], reason: DownloadReason) throws {
        let song = try db.prepare("""
            INSERT INTO songs(id, state, json, addedAt) VALUES(?, 'queued', ?, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json
            """)
        let link = try db.prepare("INSERT OR IGNORE INTO reasons(songId, reason) VALUES(?, ?)")
        for (id, json) in rows {
            try song.run([id, json, now])
            try link.run([id, reason.raw])
        }
    }

    /// Keeps `pin` with exactly `songs`: new songs are queued, songs that left lose this reason.
    /// Returns the songs that have no reason left (their files must go).
    public func pin(_ pin: DownloadPin, songs: [Song]) throws -> [Released] {
        let rows = try songs.map { ($0.id, try json($0)) }
        let pinJSON = try json(PinBox(pin.stripped)), order = try json(songs.map(\.id))
        return try write { db in
            try db.run("""
                INSERT INTO pins(reason, json, songIDs, addedAt) VALUES(?, ?, ?, ?)
                ON CONFLICT(reason) DO UPDATE SET json = excluded.json, songIDs = excluded.songIDs
                """, [pin.reason.raw, pinJSON, order, now])
            try replace(db, pin.reason, rows)
            return try prune(db)
        }
    }

    /// Gives each rule exactly its songs in `songs`; rules left out lose all theirs. Returns the songs with no reason left.
    public func setSmart(_ songs: [SmartRule: [Song]]) throws -> [Released] {
        let rows = try songs.mapValues { try $0.map { ($0.id, try json($0)) } }
        return try write { db in
            for rule in SmartRule.allCases { try replace(db, .smart(rule), rows[rule] ?? []) }
            return try prune(db)
        }
    }

    /// Songs that left `reason` lose it; new ones get it.
    private func replace(_ db: SQLiteConnection, _ reason: DownloadReason, _ rows: [(String, String)]) throws {
        let keep = Set(rows.map(\.0))
        for id in try db.rows("SELECT songId FROM reasons WHERE reason = ?", [reason.raw], { $0.text(0) ?? "" }) where !keep.contains(id) {
            try db.run("DELETE FROM reasons WHERE songId = ? AND reason = ?", [id, reason.raw])
        }
        try insert(db, rows, reason: reason)
    }

    /// Drops `reason` from `songIDs` (all songs when nil) and forgets a pin with that reason.
    public func remove(_ reason: DownloadReason, songIDs: [String]? = nil) throws -> [Released] {
        try write { db in
            if let songIDs {
                for id in songIDs { try db.run("DELETE FROM reasons WHERE songId = ? AND reason = ?", [id, reason.raw]) }
            } else {
                try db.run("DELETE FROM reasons WHERE reason = ?", [reason.raw])
                try db.run("DELETE FROM pins WHERE reason = ?", [reason.raw])
            }
            return try prune(db)
        }
    }

    public func removeAll() throws -> [Released] {
        try write { db in
            try db.exec("DELETE FROM pins")
            try db.exec("DELETE FROM reasons")
            return try prune(db)
        }
    }

    /// A song without reasons, removed from the store.
    public struct Released: Sendable, Equatable {
        public let id: String
        public let fileName: String?
    }

    private func prune(_ db: SQLiteConnection) throws -> [Released] {
        let orphans = "FROM songs WHERE NOT EXISTS (SELECT 1 FROM reasons r WHERE r.songId = songs.id)"
        let gone = try db.rows("SELECT id, fileName \(orphans)") { Released(id: $0.text(0) ?? "", fileName: $0.text(1)) }
        try db.run("DELETE \(orphans)")
        return gone
    }

    // MARK: States

    // The download steps change only a song in the state they expect, so a cancel or a removal in between wins.

    /// False when the song is no longer queued.
    func markDownloading(_ id: String) throws -> Bool {
        try update("UPDATE songs SET state = 'downloading', error = NULL WHERE id = ? AND state = 'queued'", [id])
    }

    /// False when the song was cancelled or removed meanwhile; the caller deletes the file then.
    func markDone(_ id: String, fileName: String, size: Int64, format: String, bitRate: Int?) throws -> Bool {
        try update("UPDATE songs SET state = 'done', fileName = ?, size = ?, format = ?, bitRate = ?, error = NULL WHERE id = ? AND state = 'downloading'",
                   [fileName, size, format, bitRate, id])
    }

    /// A failed download: queued again for a retry, else failed.
    func markFailure(_ id: String, error: String, retry: Bool) throws {
        _ = try update("UPDATE songs SET state = ?, error = ? WHERE id = ? AND state = 'downloading'", [retry ? "queued" : "failed", error, id])
    }

    /// Runs one UPDATE; true when it changed a row.
    private func update(_ sql: String, _ params: [any SQLConvertible]) throws -> Bool {
        try write { db in
            try db.run(sql, params)
            return try db.scalar("SELECT changes()") > 0
        }
    }

    func markFailed(_ id: String, error: String) throws {
        try write { try $0.run("UPDATE songs SET state = 'failed', error = ? WHERE id = ? AND state != 'done'", [error, id]) }
    }

    /// Puts failed songs back in the queue: `ids`, or every failure that was not a cancel.
    func requeue(_ ids: [String]? = nil) throws {
        try write { db in
            if let ids {
                for id in ids { try db.run("UPDATE songs SET state = 'queued', error = NULL WHERE id = ? AND state = 'failed'", [id]) }
            } else {
                try db.run("UPDATE songs SET state = 'queued', error = NULL WHERE state = 'failed' AND error IS NOT ?",
                           [DownloadEntry.cancelledMessage])
            }
        }
    }

    /// Downloads cut off by a quit start again.
    func resetInterrupted() throws {
        try write { try $0.exec("UPDATE songs SET state = 'queued' WHERE state = 'downloading'") }
    }

    /// Oldest queued song not in `excluding`; the user's songs come first. Without `smart`, songs only rules keep are left out.
    func nextQueued(excluding: Set<String>, smart: Bool = true) -> DownloadEntry? {
        read(nil) { db in
            let ids = try db.rows("""
                SELECT id FROM songs WHERE state = 'queued' AND (? OR \(Self.userKept)) ORDER BY NOT \(Self.userKept), addedAt, rowid LIMIT ?
                """, [smart, excluding.count + 1]) { $0.text(0) ?? "" }
            return try ids.first { !excluding.contains($0) }.flatMap { try entry(db, $0) }
        }
    }

    func setLyrics(_ id: String, _ lyrics: [StructuredLyrics]) throws {
        let text = try json(lyrics)
        try write { try $0.run("UPDATE songs SET lyrics = ? WHERE id = ?", [text, id]) }
    }

    // MARK: Reads

    public func entries() -> [DownloadEntry] {
        read([]) { db in
            let reasons = try self.reasons(db)
            return try db.rows("SELECT \(Self.columns) FROM songs ORDER BY addedAt, rowid") { decodeEntry($0, reasons) }.compactMap { $0 }
        }
    }

    public func entry(_ id: String) -> DownloadEntry? { read(nil) { try entry($0, id) } }

    private func entry(_ db: SQLiteConnection, _ id: String) throws -> DownloadEntry? {
        let reasons = Set(try db.rows("SELECT reason FROM reasons WHERE songId = ?", [id]) { $0.text(0).flatMap(DownloadReason.init(raw:)) }.compactMap { $0 })
        return try db.prepare("SELECT \(Self.columns) FROM songs WHERE id = ?").first([id]) { decodeEntry($0, [id: reasons]) } ?? nil
    }

    /// Pinned albums and playlists, newest first.
    public func pins() -> [DownloadPin] {
        read([]) { db in
            try db.rows("SELECT json FROM pins ORDER BY addedAt DESC") { row in
                row.text(0).flatMap { try? decoder.decode(PinBox.self, from: Data($0.utf8)).pin }
            }.compactMap { $0 }
        }
    }

    /// Song ids of every pin in its album or playlist order; a song in a playlist twice is listed twice.
    public func pinOrder() -> [DownloadReason: [String]] {
        read([:]) { db in
            var out: [DownloadReason: [String]] = [:]
            for (raw, text) in try db.rows("SELECT reason, songIDs FROM pins", [], { ($0.text(0) ?? "", $0.text(1) ?? "[]") }) {
                if let reason = DownloadReason(raw: raw) { out[reason] = (try? decoder.decode([String].self, from: Data(text.utf8))) ?? [] }
            }
            return out
        }
    }

    /// Stored lyrics: nil = not fetched, empty = the server has none.
    public func lyrics(_ id: String) -> [StructuredLyrics]? {
        read(nil) { db in
            try db.prepare("SELECT lyrics FROM songs WHERE id = ?").first([id]) { row in
                row.text(0).flatMap { try? decoder.decode([StructuredLyrics].self, from: Data($0.utf8)) }
            } ?? nil
        }
    }

    /// Bytes of finished files.
    public func usedBytes() -> Int64 { Int64(read(0) { try $0.scalar("SELECT COALESCE(SUM(size), 0) FROM songs WHERE state = 'done'") }) }

    /// Bytes of finished files the user keeps; the storage limit counts only these.
    public func userBytes() -> Int64 {
        Int64(read(0) { try $0.scalar("SELECT COALESCE(SUM(size), 0) FROM songs WHERE state = 'done' AND \(Self.userKept)") })
    }

    /// Songs waiting or downloading. Without `smart`, queued songs only rules keep are left out (they wait).
    func pendingCount(smart: Bool = true) -> Int {
        read(0) {
            try $0.scalar("SELECT COUNT(*) FROM songs WHERE state = 'downloading' OR (state = 'queued' AND (? OR \(Self.userKept)))", [smart])
        }
    }

    /// SQL: the song has a reason that is not a rule.
    private static let userKept = "EXISTS (SELECT 1 FROM reasons r WHERE r.songId = songs.id AND r.reason NOT LIKE 'smart:%')"

    private static let columns = "id, state, fileName, size, format, bitRate, error, json"

    private func reasons(_ db: SQLiteConnection) throws -> [String: Set<DownloadReason>] {
        var out: [String: Set<DownloadReason>] = [:]
        for (id, raw) in try db.rows("SELECT songId, reason FROM reasons", [], { ($0.text(0) ?? "", $0.text(1) ?? "") }) {
            if let reason = DownloadReason(raw: raw) { out[id, default: []].insert(reason) }
        }
        return out
    }

    private func decodeEntry(_ row: SQLiteRow, _ reasons: [String: Set<DownloadReason>]) -> DownloadEntry? {
        guard let id = row.text(0), let json = row.text(7), let song = try? decoder.decode(Song.self, from: Data(json.utf8)) else { return nil }
        return DownloadEntry(song: song, state: DownloadState(rawValue: row.text(1) ?? "") ?? .queued, fileName: row.text(2),
                             size: Int64(row.int(3)), format: row.text(4), bitRate: row.isNull(5) ? nil : row.int(5),
                             error: row.text(6), reasons: reasons[id] ?? [])
    }
}

/// Codable form of a pin.
private struct PinBox: Codable {
    var album: Album?
    var playlist: Playlist?

    init(_ pin: DownloadPin) {
        switch pin {
        case .album(let a): album = a
        case .playlist(let p): playlist = p
        }
    }

    var pin: DownloadPin? { album.map(DownloadPin.album) ?? playlist.map(DownloadPin.playlist) }
}
