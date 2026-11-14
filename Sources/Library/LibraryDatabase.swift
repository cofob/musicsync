import CryptoKit
import Foundation
import OSLog
import Subsonic
import Support

enum LibraryError: Error { case unavailable, suspiciousEmpty }

let libraryLog = Logger(subsystem: "MusicSync", category: "Library")

/// Local mirror of one server library. Every call is safe: reads return empty values and writes throw
/// when the database cannot be used, so the app can fall back to the network.
public actor LibraryDatabase {
    public nonisolated let fileURL: URL
    public nonisolated let coversDirectory: URL
    private let serverKey: String
    private var connection: SQLiteConnection?
    private var rebuilds = 0
    private var failures = 0
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    /// `serverKey` identifies server and user; each key gets its own file.
    public init(serverKey: String, directory: URL = Paths.appSupport("library"), coversDirectory: URL? = nil) {
        let hash = Self.hash(serverKey)
        self.serverKey = serverKey
        fileURL = directory.appendingPathComponent("library-\(hash).sqlite")
        self.coversDirectory = coversDirectory ?? Paths.caches("covers-small", hash)
    }

    /// Stable key for a configured server and user.
    public static func serverKey(for config: ServerConfig) -> String {
        "\(config.username.lowercased())@\(config.baseURL.absoluteString.lowercased())"
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// False when the file cannot be opened or keeps failing; callers should use the network.
    public var isHealthy: Bool { open() != nil && failures < 3 }

    // MARK: Access

    func perform<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        guard let db = open() else { throw LibraryError.unavailable }
        do {
            let result = try body(db)
            failures = 0
            return result
        } catch let error as SQLiteError where error.isCorruption {
            libraryLog.error("database corrupt, rebuilding: \(error.description)")
            replaceFile()
            failures += 1
            throw error
        } catch {
            failures += 1
            throw error
        }
    }

    /// Read helper: errors give `fallback`.
    func read<T>(_ fallback: T, _ body: (SQLiteConnection) throws -> T) -> T {
        do { return try perform(body) } catch {
            libraryLog.warning("read failed: \(String(describing: error))")
            return fallback
        }
    }

    // MARK: Meta

    func meta(_ key: String) -> String? {
        read(nil) { try $0.prepare("SELECT value FROM meta WHERE key = ?").first([key]) { $0.text(0) } ?? nil }
    }

    func setMeta(_ pairs: [String: String?]) throws {
        try perform { db in
            try db.transaction {
                for (key, value) in pairs {
                    if let value {
                        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
                    } else {
                        try db.run("DELETE FROM meta WHERE key = ?", [key])
                    }
                }
            }
        }
    }

    // MARK: Opening and recovery

    private func open() -> SQLiteConnection? {
        if let connection { return connection }
        do {
            connection = try openChecked()
        } catch let error as SQLiteError where error.isCorruption {
            libraryLog.error("unusable database, starting fresh: \(error.description)")
            replaceFile()
        } catch {
            libraryLog.error("cannot open database: \(String(describing: error))")  // transient: retried on next call
        }
        return connection
    }

    /// Opens the file and verifies integrity, schema version and server. Creates the schema in a new file.
    private func openChecked() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: fileURL.path)
        try db.exec("PRAGMA journal_mode = WAL")
        try db.exec("PRAGMA synchronous = NORMAL")
        try db.exec("PRAGMA foreign_keys = ON")
        guard try db.rows("PRAGMA quick_check(1)", [], { $0.text(0) }).first == "ok" else {
            throw SQLiteError(code: 11, message: "quick_check failed")
        }
        let version = try db.scalar("PRAGMA user_version")
        if version == 0 {
            try db.transaction {
                for sql in Schema.statements { try db.exec(sql) }
                try db.run("INSERT INTO meta(key, value) VALUES('serverKey', ?)", [serverKey])
                try db.exec("PRAGMA user_version = \(Schema.version)")
            }
        } else {
            let stored = try db.prepare("SELECT value FROM meta WHERE key = 'serverKey'").first { $0.text(0) } ?? nil
            guard version == Schema.version, stored == serverKey else {
                throw SQLiteError(code: 26, message: "schema \(version) or server mismatch")
            }
        }
        return db
    }

    /// Moves the file aside (kept for inspection, newest two) and creates an empty database.
    private func replaceFile() {
        connection = nil
        rebuilds += 1
        guard rebuilds <= 3 else { return }  // do not loop on a disk that keeps failing
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let aside = fileURL.appendingPathExtension("corrupt-\(stamp)")
        try? fm.removeItem(at: aside)
        try? fm.moveItem(at: fileURL, to: aside)
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: fileURL.path + suffix) }
        pruneAsideFiles()
        do { connection = try openChecked() } catch {
            libraryLog.error("cannot create fresh database: \(String(describing: error))")
            try? fm.removeItem(at: fileURL)
        }
    }

    private func pruneAsideFiles() {
        let dir = fileURL.deletingLastPathComponent()
        let prefix = fileURL.lastPathComponent + ".corrupt-"
        let old = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted().dropLast(2)
        for name in old { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
}
