import Foundation
import ITunesDB
import Transcode

/// Server metadata -> iTunesDB track.
enum TrackBuilder {
    /// Metadata fields shared by new tracks and retags.
    static func applyTags(_ d: DesiredSong, to t: inout Track) {
        let tags = d.tags
        t.title = tags.title; t.artist = tags.artist; t.album = tags.album
        t.albumArtist = tags.albumArtist; t.genre = tags.genre
        t.year = UInt32(clamping: tags.year ?? 0)
        t.trackNumber = UInt32(clamping: tags.trackNumber ?? 0); t.trackCount = UInt32(clamping: tags.trackTotal ?? 0)
        t.discNumber = UInt32(clamping: tags.discNumber ?? 0); t.discCount = UInt32(clamping: tags.discTotal ?? 0)
        t.compilation = tags.compilation
        t.soundcheck = d.soundCheckGain.map(soundcheck(fromReplayGainDB:)) ?? 0
    }

    static func make(_ d: DesiredSong, prepared p: Prepared, relativePath: String, size: Int64, now: Date = Date()) -> Track {
        var t = Track()
        applyTags(d, to: &t)
        t.dbid = UInt64.random(in: 1...UInt64.max)
        t.location = ITunesDB.ipodLocation(relativePath: relativePath)
        t.filetype = p.ext == "mp3" ? "MP3 " : "M4A "
        t.size = UInt32(clamping: size)
        t.lengthMs = UInt32(clamping: Int((p.output.durationSeconds * 1000).rounded()))
        t.bitrate = UInt32(clamping: (p.output.bitRate ?? 0) / 1000)
        t.sampleRate = UInt32(clamping: p.output.sampleRate)
        t.playCount = UInt32(clamping: d.song.playCount ?? 0)
        t.rating = UInt8(SyncPlanner.rating(d.song) * 20)
        t.lyricsFlag = p.hasLyrics
        t.timeAdded = now
        t.timeModified = now
        if let g = p.gapless {
            t.pregap = UInt32(clamping: g.pregap); t.postgap = UInt32(clamping: g.postgap)
            t.sampleCount = UInt64(clamping: g.sampleCount)
            t.gaplessTrackFlag = true
            t.gaplessAlbumFlag = p.transcoded
        }
        return t
    }
}
