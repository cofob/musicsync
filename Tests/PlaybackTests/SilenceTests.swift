@testable import Playback
import Testing

/// Tests never make a sound, even when one sets the volume.
@MainActor @Suite struct SilenceTests {
    @Test func decksAreMutedInTests() {
        let mixer = Mixer()
        mixer.volume = 1
        #expect(Deck.silent)
        #expect(mixer.decks.allSatisfy { $0.player.volume == 0 })
    }
}
