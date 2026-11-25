import Foundation
import Subsonic

/// Music videos found on other hosts than the server, so each song is looked up once.
extension LibraryDatabase {
    /// Outer nil = not asked yet (or an old "none"), inner nil = none found.
    public func externalVideo(songId: String) -> MusicVideo?? {
        let cutoff = Date().timeIntervalSince1970 - Self.retryAfter
        return read(nil) { db in
            try db.prepare("SELECT json FROM external_videos WHERE songId = ? AND (json IS NOT NULL OR fetchedAt > ?)")
                .first([songId, cutoff], { row -> MusicVideo? in row.text(0) == nil ? nil : decode(MusicVideo.self, row) })
        }
    }

    /// Nil stores the "none" marker.
    public func storeExternalVideo(songId: String, video: MusicVideo?) throws {
        let text = try video.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try write {
            try $0.run("""
                INSERT INTO external_videos(songId, json, fetchedAt) VALUES(?, ?, ?)
                ON CONFLICT(songId) DO UPDATE SET json = excluded.json, fetchedAt = excluded.fetchedAt
                """, [songId, text, Date().timeIntervalSince1970])
        }
    }
}
