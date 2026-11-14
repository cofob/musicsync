import Foundation
import Subsonic

/// Lyrics as shown in Now Playing. Line `start` is in seconds and nil for unsynced lyrics.
struct Lyrics: Sendable {
    struct Line: Hashable, Sendable {
        let start: TimeInterval?
        let text: String
    }

    let lines: [Line]
    var isSynced: Bool { lines.first?.start != nil }

    /// Nil when there are no lines.
    init?(_ lyrics: StructuredLyrics) {
        let offset = Double(lyrics.offset ?? 0)
        lines = lyrics.line.map { Line(start: lyrics.synced ? $0.start.map { (Double($0) + offset) / 1000 } : nil, text: $0.value) }
        if lines.isEmpty { return nil }
    }

    /// Nil for empty text.
    init?(plain: String) {
        let text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        lines = text.components(separatedBy: .newlines).map { Line(start: nil, text: $0) }
    }
}
