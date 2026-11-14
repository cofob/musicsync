import Foundation
import Playback
import Testing

@Suite struct MeteredQualityTests {
    @Test func defaultsKeepTodaysQuality() throws {
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"quality":"aac","maxBitRate":192}"#.utf8))
        #expect(settings.meteredQuality == nil)
        #expect(settings.meteredMaxBitRate == 128)
        #expect(settings.network(metered: true) == settings)
        #expect(settings.network(metered: true).stream(for: song("a")).maxBitRate == 192)
    }

    @Test func meteredNetworkUsesItsQuality() throws {
        var settings = PlaybackSettings()
        settings.meteredQuality = .mp3
        settings.meteredMaxBitRate = 96
        let flac = song("a")
        #expect(settings.network(metered: false).stream(for: flac).format == "raw")
        #expect(settings.network(metered: true).stream(for: flac) == StreamRequest(format: "mp3", maxBitRate: 96, contentType: "audio/mpeg"))
        let saved = try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved == settings)
    }

    @Test func titles() {
        #expect(StreamRequest(format: "raw").title == "Original")
        #expect(StreamRequest(format: "aac", maxBitRate: 256).title == "AAC 256 kbps")
    }
}
