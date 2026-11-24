import Foundation
import Support

/// Picks presets by mood.
public enum MoodMatcher {
    /// One of the `count` candidates closest to `target`, chosen by `random` (0..<1), none of `avoiding`.
    /// Nil when no candidate is left.
    public static func pick(_ candidates: [(name: String, mood: Mood)], near target: Mood, avoiding: Set<String> = [],
                            among count: Int = 5, random: Double) -> String? {
        let closest = candidates.filter { !avoiding.contains($0.name) }
            .sorted { ($0.mood.distance(to: target), $0.name) < ($1.mood.distance(to: target), $1.name) }
            .prefix(max(count, 1))
        guard !closest.isEmpty else { return nil }
        return closest[min(Int(random * Double(closest.count)), closest.count - 1)].name
    }
}
