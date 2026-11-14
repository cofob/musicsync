import Foundation

/// Names compared loosely: case, accents, punctuation and "feat." clauses do not matter.
public enum Normalizer {
    private static let featuring = try! NSRegularExpression(
        pattern: #"[\(\[]?\b(?:feat|ft|featuring)\b\.?[^\)\]]*[\)\]]?"#, options: .caseInsensitive)

    public static func key(_ text: String) -> String {
        var s = text
        s = featuring.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = s.replacingOccurrences(of: "&", with: " and ")
        s = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
