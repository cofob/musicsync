import Foundation
import Playback
import Subsonic
import Testing

func decode<T: Decodable>(_ json: [String: Any]) -> T {
    try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
}

func song(_ id: String, album: String? = "al-1", track: Int? = 1, disc: Int? = nil, suffix: String = "flac",
          gain: [String: Double]? = nil) -> Song {
    var json: [String: Any] = ["id": id, "title": "Song \(id)", "suffix": suffix, "contentType": "audio/\(suffix)", "duration": 200]
    json["albumId"] = album
    json["track"] = track
    json["discNumber"] = disc
    json["replayGain"] = gain
    return decode(json)
}

@Suite struct SettingsTests {
    @Test func savesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "playback-test-\(UUID().uuidString)"))
        #expect(PlaybackSettings.load(from: defaults) == PlaybackSettings())
        var settings = PlaybackSettings()
        settings.crossfade = true
        settings.crossfadeSeconds = 9
        settings.soundCheck = .album
        settings.speed = 1.5
        settings.save(to: defaults)
        #expect(PlaybackSettings.load(from: defaults) == settings)
    }

    @Test func oldSettingsKeepDefaults() throws {
        let settings = try JSONDecoder().decode(PlaybackSettings.self, from: Data(#"{"crossfade":true}"#.utf8))
        #expect(settings.crossfade)
        #expect(settings.crossfadeSeconds == 6)
        #expect(settings.soundCheck == .off)
    }

    @Test func streamRequests() {
        var settings = PlaybackSettings()
        let flac = song("a"), ogg = song("b", suffix: "ogg")
        #expect(settings.stream(for: flac) == StreamRequest(format: "raw", maxBitRate: nil, contentType: "audio/flac"))
        #expect(settings.stream(for: ogg) == StreamRequest(format: "mp3", maxBitRate: 320, contentType: "audio/mpeg"))
        #expect(settings.stream(for: flac, fallback: true).format == "mp3")
        #expect(!settings.stream(for: flac).isConverted)

        settings.quality = .aac
        settings.maxBitRate = 192
        #expect(settings.stream(for: flac) == StreamRequest(format: "aac", maxBitRate: 192, contentType: "audio/aac"))
        #expect(settings.stream(for: flac, fallback: true) == StreamRequest(format: "mp3", maxBitRate: 192, contentType: "audio/mpeg"))
        settings.quality = .mp3
        #expect(settings.stream(for: ogg).maxBitRate == 192)
        #expect(settings.stream(for: ogg).isConverted)
    }

    @Test func sleepTimerDeadline() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(SleepTimer.minutes(15).deadline(from: start) == Date(timeIntervalSince1970: 1900))
        #expect(SleepTimer.endOfSong.deadline(from: start) == nil)
        #expect(SleepTimer.choices.count == 5)
        #expect(SleepTimer.minutes(45).title == "45 Minutes")
    }
}
