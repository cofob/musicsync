import AVFoundation
import Playback

/// `check:quality`: the streaming quality, also the one for metered networks, sets the stream URL parameters.
extension ShotChecks {
    static func quality(_ model: AppModel) async {
        guard model.config?.baseURL.host == "127.0.0.1" else { return check(false, "quality needs MUSICSYNC_DEMO_SERVER on 127.0.0.1") }
        let player = model.player
        let saved = player.settings
        defer { player.settings = saved; player.isMetered = false; PlaybackSettings().save() }
        await Shot.playPaused(model)
        guard let index = player.index else { return check(false, "a song is current") }
        /// The `format` and `maxBitRate` of the stream URL the player would open now.
        func params() -> String {
            guard let url = (player.cue(at: index)?.item.asset as? AVURLAsset)?.url,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return "no stream" }
            let value = { name in items.first { $0.name == name }?.value ?? "-" }
            return "\(value("format")) \(value("maxBitRate"))"
        }
        var settings = PlaybackSettings()
        player.settings = settings
        check(["raw -", "mp3 320"].contains(params()), "original: \(params())")
        settings.quality = .mp3
        settings.maxBitRate = 128
        player.settings = settings
        check(params() == "mp3 128", "MP3 128: \(params())")
        player.isMetered = true
        check(params() == "mp3 128", "metered without its own quality keeps MP3 128: \(params())")
        settings.meteredQuality = .aac
        settings.meteredMaxBitRate = 96
        player.settings = settings
        check(params() == "aac 96", "metered AAC 96: \(params())")
        check(player.activeQuality == "AAC 96 kbps", "info shows the metered quality: \(player.activeQuality ?? "nil")")
        player.isMetered = false
        check(params() == "mp3 128", "back on Wi-Fi: \(params())")
    }
}
