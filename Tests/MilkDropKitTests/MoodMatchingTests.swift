import Foundation
@testable import MilkDropKit
import Support
import Testing

@Suite struct MoodMatchingTests {
    private let candidates: [(name: String, mood: Mood)] = [
        ("calm", Mood(arousal: 0.1, valence: 0.5, tension: 0.1)),
        ("dark", Mood(arousal: 0.4, valence: 0.1, tension: 0.8)),
        ("happy", Mood(arousal: 0.8, valence: 0.9, tension: 0.2)),
        ("wild", Mood(arousal: 0.9, valence: 0.5, tension: 0.9)),
    ]
    private let target = Mood(arousal: 0.85, valence: 0.85, tension: 0.25)

    @Test func picksTheNearest() {
        #expect(MoodMatcher.pick(candidates, near: target, among: 1, random: 0.9) == "happy")
    }

    @Test func choosesAmongTheClosestN() {
        let picks = (0..<10).map { MoodMatcher.pick(candidates, near: target, among: 2, random: Double($0) / 10) }
        #expect(Set(picks) == ["happy", "wild"])  // the two closest, nothing else
    }

    @Test func neverRepeatsWhatIsAvoided() {
        #expect(MoodMatcher.pick(candidates, near: target, avoiding: ["happy"], among: 1, random: 0) == "wild")
        #expect(MoodMatcher.pick(candidates, near: target, avoiding: Set(candidates.map(\.name)), random: 0) == nil)
        #expect(MoodMatcher.pick([], near: target, random: 0) == nil)
    }

    @Test func moodDistanceAndMixing() {
        let a = Mood(arousal: 0, valence: 0, tension: 0), b = Mood(arousal: 1, valence: 1, tension: 1)
        #expect(abs(a.distance(to: b) - 3.0.squareRoot()) < 1e-9)
        #expect(a.mixed(with: b, 0.25) == Mood(arousal: 0.25, valence: 0.25, tension: 0.25))
        #expect(Mood(arousal: 2, valence: -1, tension: .nan) == Mood(arousal: 1, valence: 0, tension: 0.5))
    }
}
