import CryptoKit
import Foundation
import ITunesDB
import Subsonic
import Transcode

/// A song the selection wants on the device, with everything needed to write it.
public struct DesiredSong: Sendable, Hashable, Identifiable {
    public let song: Song
    public let preset: Preset
    public let tags: TrackTags
    public let coverArtID: String?
    /// ReplayGain in dB chosen by the Sound Check setting.
    public let soundCheckGain: Double?
    /// Changes when the DB-visible metadata changes (retag trigger).
    public let fingerprint: String

    public var id: String { song.id }
    public var albumID: String { song.albumId ?? "" }

    public init(song: Song, preset: Preset, tags: TrackTags, coverArtID: String? = nil, soundCheckGain: Double? = nil) {
        self.song = song
        self.preset = preset
        self.tags = tags
        self.coverArtID = coverArtID
        self.soundCheckGain = soundCheckGain
        var parts = [tags.title, tags.artist, tags.album, tags.albumArtist, tags.genre, tags.composer,
                     String(tags.year ?? 0), String(tags.trackNumber ?? 0), String(tags.trackTotal ?? 0),
                     String(tags.discNumber ?? 0), String(tags.discTotal ?? 0), tags.compilation ? "1" : "0"]
        // Rockbox files carry no Sound Check value.
        if preset.target == .stock { parts.append(String(soundCheckGain.map(soundcheck(fromReplayGainDB:)) ?? 0)) }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// A server playlist reduced to ordered song ids.
public struct DesiredPlaylist: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let songIDs: [String]

    public init(id: String, name: String, songIDs: [String]) {
        self.id = id
        self.name = name
        self.songIDs = songIDs
    }
}
