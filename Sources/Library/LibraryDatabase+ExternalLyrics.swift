import Foundation
import Subsonic

/// Lyrics from other sources than the server (LRCLIB), kept apart so server lyrics always win.
extension LibraryDatabase {
    /// Outer nil = not asked yet (or an old "none"), inner nil = the source has none.
    public func externalLyrics(songId: String, source: String) -> StructuredLyrics?? {
        let cutoff = Date().timeIntervalSince1970 - Self.retryAfter
        return read(nil) { db in
            try db.prepare("SELECT json FROM external_lyrics WHERE songId = ? AND source = ? AND (json IS NOT NULL OR fetchedAt > ?)")
                .first([songId, source, cutoff], { row -> StructuredLyrics? in row.text(0) == nil ? nil : decode(StructuredLyrics.self, row) })
        }
    }

    /// Nil stores the "none" marker.
    public func storeExternalLyrics(songId: String, source: String, lyrics: StructuredLyrics?) throws {
        let text = try lyrics.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try write {
            try $0.run("""
                INSERT INTO external_lyrics(songId, source, json, fetchedAt) VALUES(?, ?, ?, ?)
                ON CONFLICT(songId, source) DO UPDATE SET json = excluded.json, fetchedAt = excluded.fetchedAt
                """, [songId, source, text, Date().timeIntervalSince1970])
        }
    }
}
