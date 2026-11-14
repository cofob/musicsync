import Foundation
import SQLite3

/// A failed SQLite call. `code` is the primary result code.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    init(_ handle: OpaquePointer?) {
        self.init(code: sqlite3_errcode(handle) & 0xFF, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle")
    }

    /// The file itself is unusable and must be replaced.
    var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
    var description: String { "SQLite \(code): \(message)" }
}

// MARK: - Values

protocol SQLConvertible { func bind(_ stmt: OpaquePointer?, at index: Int32) -> Int32 }

extension Int: SQLConvertible { func bind(_ s: OpaquePointer?, at i: Int32) -> Int32 { sqlite3_bind_int64(s, i, Int64(self)) } }
extension Int64: SQLConvertible { func bind(_ s: OpaquePointer?, at i: Int32) -> Int32 { sqlite3_bind_int64(s, i, self) } }
extension Bool: SQLConvertible { func bind(_ s: OpaquePointer?, at i: Int32) -> Int32 { sqlite3_bind_int64(s, i, self ? 1 : 0) } }
extension Double: SQLConvertible { func bind(_ s: OpaquePointer?, at i: Int32) -> Int32 { sqlite3_bind_double(s, i, self) } }
extension String: SQLConvertible {
    func bind(_ s: OpaquePointer?, at i: Int32) -> Int32 {
        sqlite3_bind_text(s, i, self, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))  // SQLITE_TRANSIENT
    }
}
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    func bind(_ s: OpaquePointer?, at i: Int32) -> Int32 { self?.bind(s, at: i) ?? sqlite3_bind_null(s, i) }
}

/// A result row. Column indexes start at 0.
struct SQLiteRow {
    fileprivate let stmt: OpaquePointer?

    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
}

// MARK: - Statement

final class SQLiteStatement: @unchecked Sendable {
    private var stmt: OpaquePointer?
    private let db: OpaquePointer?

    fileprivate init(db: OpaquePointer?, sql: String) throws {
        self.db = db
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SQLiteError(db) }
    }

    deinit { sqlite3_finalize(stmt) }

    /// Runs the statement to completion, ignoring result rows.
    func run(_ params: [any SQLConvertible] = []) throws {
        _ = try rows(params) { _ in () }
    }

    /// Runs the statement and maps every result row.
    func rows<T>(_ params: [any SQLConvertible] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        defer { sqlite3_reset(stmt) }  // releases read locks even on early exit
        for (i, value) in params.enumerated() where value.bind(stmt, at: Int32(i + 1)) != SQLITE_OK { throw SQLiteError(db) }
        var out: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: out.append(try map(SQLiteRow(stmt: stmt)))
            case SQLITE_DONE: return out
            default: throw SQLiteError(db)
            }
        }
    }

    func first<T>(_ params: [any SQLConvertible] = [], _ map: (SQLiteRow) throws -> T) throws -> T? {
        try rows(params, map).first
    }
}

// MARK: - Connection

/// One SQLite connection. Not thread safe: the owning actor serializes access.
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = SQLiteError(handle)
            sqlite3_close_v2(handle)
            // `deinit` runs for a failed init too. Closing the freed pointer again could close
            // another thread's new connection that got the same address.
            handle = nil
            throw error
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close_v2(handle) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteError(handle) }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement { try SQLiteStatement(db: handle, sql: sql) }

    func run(_ sql: String, _ params: [any SQLConvertible] = []) throws { try prepare(sql).run(params) }

    func rows<T>(_ sql: String, _ params: [any SQLConvertible] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        try prepare(sql).rows(params, map)
    }

    func scalar(_ sql: String, _ params: [any SQLConvertible] = []) throws -> Int {
        try prepare(sql).first(params) { $0.int(0) } ?? 0
    }

    /// Runs `body` in one write transaction; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
