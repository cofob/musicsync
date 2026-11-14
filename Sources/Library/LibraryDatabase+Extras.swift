import Foundation
import ImageIO
import Subsonic
import Support

/// Cover thumbnails and lyrics: optional extras with their own retry rules.
extension LibraryDatabase {
    /// Placeholder shown at once while the full cover loads from the server.
    static let smallCoverSize = 96
    /// A failed cover fetch or an empty lyrics reply is retried after this long.
    static let retryAfter: TimeInterval = 30 * 24 * 3600

    // MARK: Covers

    /// Cover ids of albums without a thumbnail (failed fetches wait `retryAfter`).
    func coversToFetch(limit: Int = .max) -> [String] {
        let cutoff = Date().timeIntervalSince1970 - Self.retryAfter
        return read([]) {
            try $0.rows("""
                SELECT DISTINCT coverArt FROM albums WHERE coverArt IS NOT NULL AND coverArt != '' AND NOT EXISTS (
                  SELECT 1 FROM covers c WHERE c.coverArtId = albums.coverArt AND c.size = ?
                    AND (c.path IS NOT NULL OR c.fetchedAt > ?)) LIMIT ?
                """, [Self.smallCoverSize, cutoff, min(limit, Int(Int32.max))]) { $0.text(0)! }
        }
    }

    private func coverFileName(_ id: String) -> String { "\(Self.hash(id))-\(Self.smallCoverSize)" }

    /// Writes the image next to the other thumbnails and records it.
    func storeCover(id: String, data: Data) throws {
        let name = coverFileName(id)
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try FileManager.default.atomicWrite(Self.compactCover(data), to: coversDirectory.appendingPathComponent(name))
        try recordCover(id: id, path: name)
    }

    /// Scales a cover to `smallCoverSize` JPEG (~5 KB; Navidrome sends PNG). JPEG decodes ~20x faster than HEIC/AVIF.
    /// Data that is not an image is kept as is.
    static func compactCover(_ data: Data) -> Data {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: smallCoverSize] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return data }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : data
    }

    /// Remembers that the server has no usable cover, so it is not asked again for a while.
    func recordMissingCover(id: String) throws { try recordCover(id: id, path: nil) }

    private func recordCover(id: String, path: String?) throws {
        try write {
            try $0.run("""
                INSERT INTO covers(coverArtId, size, path, fetchedAt) VALUES(?, ?, ?, ?)
                ON CONFLICT(coverArtId, size) DO UPDATE SET path = excluded.path, fetchedAt = excluded.fetchedAt
                """, [id, Self.smallCoverSize, path, Date().timeIntervalSince1970])
        }
    }

    // MARK: Lyrics

    /// Songs without lyrics rows (or with an old "none" marker), most played first.
    func songsMissingLyrics(limit: Int) -> [String] {
        let cutoff = Date().timeIntervalSince1970 - Self.retryAfter
        return read([]) {
            try $0.rows("""
                SELECT id FROM songs WHERE NOT EXISTS (
                  SELECT 1 FROM lyrics l WHERE l.songId = songs.id AND (l.status = 'found' OR l.fetchedAt > ?))
                ORDER BY playCount DESC, COALESCE(created, '') DESC LIMIT ?
                """, [cutoff, limit]) { $0.text(0)! }
        }
    }

    /// An empty list stores the "none" marker.
    public func storeLyrics(songId: String, lyrics: [StructuredLyrics]) throws {
        let text = lyrics.isEmpty ? nil : String(decoding: try encoder.encode(lyrics), as: UTF8.self)
        try write {
            try $0.run("""
                INSERT INTO lyrics(songId, status, synced, json, fetchedAt) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(songId) DO UPDATE SET status = excluded.status, synced = excluded.synced,
                  json = excluded.json, fetchedAt = excluded.fetchedAt
                """, [songId, text == nil ? "none" : "found", lyrics.contains { $0.synced }, text, Date().timeIntervalSince1970])
        }
    }
}
