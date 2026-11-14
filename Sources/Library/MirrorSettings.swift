import Foundation

public struct MirrorSettings: Codable, Equatable, Sendable {
    /// When false nothing runs in the background; `syncNow()` still works.
    public var enabled = true
    public var intervalMinutes = 30
    public var includeLyrics = true
    public var includeCovers = true
    /// Pause before each request.
    public var throttleMs = 50
    /// At most this many songs get lyrics per pass, so a big library fills in over time.
    public var lyricsPerPass = 500

    public init() {}

    // Missing keys take defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MirrorSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? d.intervalMinutes
        includeLyrics = try c.decodeIfPresent(Bool.self, forKey: .includeLyrics) ?? d.includeLyrics
        includeCovers = try c.decodeIfPresent(Bool.self, forKey: .includeCovers) ?? d.includeCovers
        throttleMs = try c.decodeIfPresent(Int.self, forKey: .throttleMs) ?? d.throttleMs
        lyricsPerPass = try c.decodeIfPresent(Int.self, forKey: .lyricsPerPass) ?? d.lyricsPerPass
    }
}
