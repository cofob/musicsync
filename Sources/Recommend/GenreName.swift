import Foundation

/// Genre tags as people write them: "Hip-Hop", "hip hop" and "HipHop" are one genre, "Rock; Pop" are two.
public enum GenreName {
    /// Grouping key: case, accents, spaces and punctuation do not count, and "&" is "and".
    public static func key(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).replacingOccurrences(of: "&", with: "and")
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    /// The genres in one tag: "Rock; Pop/Indie" -> ["Rock", "Pop", "Indie"], trimmed, each genre once.
    public static func split(_ tag: String?) -> [String] {
        var seen = Set<String>()
        return (tag ?? "").split(whereSeparator: { ";/,".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !key($0).isEmpty && seen.insert(key($0)).inserted }
    }

    /// The name to show for each key: its most common spelling; a tie goes to the first in sort order.
    public static func displayNames(_ counts: [String: Int]) -> [String: String] {
        var best: [String: (name: String, count: Int)] = [:]
        for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
            let key = key(name)
            guard !key.isEmpty, count > best[key]?.count ?? 0 else { continue }
            best[key] = (name, count)
        }
        return best.mapValues(\.name)
    }
}
