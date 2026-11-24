import Foundation

/// A mood as three numbers, each 0…1: songs and visualizer presets are placed in this one space to be matched.
public struct Mood: Codable, Equatable, Sendable {
    /// Calm to energetic: loud, busy, fast songs; moving, beat-driven pictures.
    public var arousal: Double
    /// Dark to bright: minor and dull to major and shining; dark pictures to light, warm ones.
    public var valence: Double
    /// Relaxed to tense: dissonant, strongly changing songs; harsh, high-contrast pictures.
    public var tension: Double

    public init(arousal: Double, valence: Double, tension: Double) {
        self.arousal = Self.clamp(arousal)
        self.valence = Self.clamp(valence)
        self.tension = Self.clamp(tension)
    }

    /// Straight distance in the space, 0…√3.
    public func distance(to other: Mood) -> Double {
        let (a, v, t) = (arousal - other.arousal, valence - other.valence, tension - other.tension)
        return (a * a + v * v + t * t).squareRoot()
    }

    /// This mood moved toward `other` by `amount` (0 stays, 1 is `other`).
    public func mixed(with other: Mood, _ amount: Double) -> Mood {
        Mood(arousal: arousal + (other.arousal - arousal) * amount, valence: valence + (other.valence - valence) * amount,
             tension: tension + (other.tension - tension) * amount)
    }

    /// `x` mapped from `low…high` to 0…1, and cut off outside.
    public static func scaled(_ x: Double, _ low: Double, _ high: Double) -> Double { clamp((x - low) / (high - low)) }

    private static func clamp(_ x: Double) -> Double { x.isNaN ? 0.5 : min(max(x, 0), 1) }
}
