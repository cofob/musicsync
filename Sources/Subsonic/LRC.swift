import Foundation

/// Parser for LRC lyrics files: `[mm:ss.xx]text`, several times per line, an `[offset:ms]` tag.
public enum LRC {
    /// Synced lyrics, or nil when no line has a time.
    public static func parse(_ text: String) -> StructuredLyrics? {
        var offset = 0
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var starts: [Int] = []
            while rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<end]
                if let ms = time(tag) {
                    starts.append(ms)
                } else if tag.lowercased().hasPrefix("offset:"), let value = Int(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    offset = value
                }
                rest = rest[rest.index(after: end)...]
            }
            let value = rest.replacing(/<\d+:\d+(?:[.:]\d+)?>/, with: "").trimmingCharacters(in: .whitespaces)
            lines += starts.map { LyricLine(start: $0, value: value) }
        }
        guard !lines.isEmpty else { return nil }
        // A positive LRC offset shows the lines sooner.
        return StructuredLyrics(displayArtist: nil, displayTitle: nil, lang: nil, offset: offset == 0 ? nil : -offset,
                                synced: true, line: lines.sorted { ($0.start ?? 0) < ($1.start ?? 0) })
    }

    /// Unsynced lyrics, or nil for empty text.
    public static func plain(_ text: String) -> StructuredLyrics? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return StructuredLyrics(displayArtist: nil, displayTitle: nil, lang: nil, offset: nil, synced: false,
                                line: trimmed.components(separatedBy: .newlines).map { LyricLine(start: nil, value: $0) })
    }

    /// Milliseconds of `mm:ss`, `mm:ss.xx`, `mm:ss.xxx` or `mm:ss:xx`; nil for other tags.
    static func time(_ tag: Substring) -> Int? {
        guard let match = tag.wholeMatch(of: /(\d+):(\d{1,2})(?:[.:](\d{1,3}))?/),
              let minutes = Int(match.1), let seconds = Int(match.2) else { return nil }
        let fraction = match.3.map { String($0) } ?? ""
        let ms = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return (minutes * 60 + seconds) * 1000 + ms
    }
}
