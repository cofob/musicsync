import Foundation

extension LibraryDatabase {
    /// Cover art id -> local thumbnail file, for all stored thumbnails in one query (Spotlight).
    public func smallCoverURLs() -> [String: URL] {
        let rows: [(String, String)] = read([]) {
            try $0.rows("SELECT coverArtId, path FROM covers WHERE size = ? AND path IS NOT NULL", [Self.smallCoverSize]) { row in
                (row.text(0) ?? "", row.text(1) ?? "")
            }
        }
        return Dictionary(rows.map { ($0.0, coversDirectory.appendingPathComponent($0.1)) }) { first, _ in first }
    }
}
