import Foundation
import Recommend
import Support

/// Local log of listening events for one server. It has its own file: unlike the mirror it cannot be fetched
/// from the server again, so a library reset or schema change must not touch it. Keeps the newest `limit` events.
public actor PlayHistory {
    public nonisolated let fileURL: URL
    private let limit: Int
    private var connection: SQLiteConnection?

    public init(serverKey: String, directory: URL = Paths.appSupport("library"), limit: Int = 50_000) {
        fileURL = directory.appendingPathComponent("history-\(LibraryDatabase.hash(serverKey)).sqlite")
        self.limit = limit
    }

    public func record(_ event: PlayEvent) throws {
        let db = try open()
        try db.run("INSERT INTO plays(songId, startedAt, played, duration, completed, source) VALUES(?, ?, ?, ?, ?, ?)",
                   [event.songId, event.startedAt.timeIntervalSince1970, event.played, event.duration, event.completed, event.source.rawValue])
        try db.run("DELETE FROM plays WHERE id <= (SELECT MAX(id) FROM plays) - ?", [limit])  // a rowid range: cheap
    }

    /// The newest `limit` events, oldest first.
    public func events(limit: Int = 5000) -> [PlayEvent] {
        read([]) { db in
            Array(try db.rows("SELECT songId, startedAt, played, duration, source FROM plays ORDER BY id DESC LIMIT ?", [limit]) { row in
                PlayEvent(songId: row.text(0) ?? "", startedAt: Date(timeIntervalSince1970: row.double(1)), played: row.double(2),
                          duration: row.double(3), source: row.text(4).flatMap(PlaySource.init) ?? .other)
            }.reversed())
        }
    }

    /// Plays, skips, last play and mean completion of every song in the log.
    public func stats() -> [String: SongStats] {
        read([:]) { db in
            let rows = try db.rows("""
                SELECT songId, SUM(completed), SUM(1 - completed), MAX(startedAt),
                       AVG(CASE WHEN duration > 0 THEN MIN(1.0, played / duration) END)
                FROM plays GROUP BY songId
                """) { row in
                (row.text(0) ?? "", SongStats(plays: row.int(1), skips: row.int(2), lastPlayed: Date(timeIntervalSince1970: row.double(3)),
                                              completion: row.isNull(4) ? 1 : row.double(4)))
            }
            return Dictionary(rows) { a, _ in a }
        }
    }

    private func read<T>(_ fallback: T, _ body: (SQLiteConnection) throws -> T) -> T {
        do { return try body(try open()) } catch {
            libraryLog.warning("history read failed: \(String(describing: error))")
            return fallback
        }
    }

    private func open() throws -> SQLiteConnection {
        if let connection { return connection }
        let db = try SQLiteConnection(path: fileURL.path)
        try db.exec("PRAGMA journal_mode = WAL")
        try db.exec("PRAGMA synchronous = NORMAL")
        try db.exec("""
            CREATE TABLE IF NOT EXISTS plays(
              id INTEGER PRIMARY KEY, songId TEXT NOT NULL, startedAt REAL NOT NULL, played REAL NOT NULL,
              duration REAL NOT NULL, completed INTEGER NOT NULL, source TEXT NOT NULL)
            """)
        try db.exec("CREATE INDEX IF NOT EXISTS plays_song ON plays(songId)")
        connection = db
        return db
    }
}
