import Foundation

/// Finds library items by the name that Shortcuts or Siri gives.
public enum NameMatch {
    /// The items whose name matches `text`, best first: the same name, then names that start with it, then names
    /// that hold every word of it. Case, accents and width do not count; equal matches keep the list order.
    public static func rank<T>(_ items: [T], by name: (T) -> String, matching text: String) -> [T] {
        let typed = fold(text.trimmingCharacters(in: .whitespaces))
        let words = typed.split(separator: " ")
        guard !words.isEmpty else { return [] }
        let scored = items.enumerated().compactMap { i, item -> (score: Int, index: Int, item: T)? in
            let n = fold(name(item))
            if n == typed { return (0, i, item) }
            if n.hasPrefix(typed) { return (1, i, item) }
            return words.allSatisfy(n.contains) ? (2, i, item) : nil
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.item)
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
}
