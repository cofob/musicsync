import Foundation

public extension String {
    /// At most `limit` characters, ending in "…" when cut; for labels that cannot truncate by width, like a menu bar title.
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return prefix(max(limit - 1, 0)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
