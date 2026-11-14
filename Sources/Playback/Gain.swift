import Foundation
import Subsonic

public extension PlaybackSettings {
    /// Linear volume factor for `song` from its ReplayGain. `inAlbumOrder` picks the album gain in Album mode.
    /// The result is at most 1: AVFoundation cannot amplify. `baseGain` (Opus output gain) is not added:
    /// the decoder applies it already, and the player gets Ogg files converted anyway.
    func gain(for song: Song?, inAlbumOrder: Bool) -> Float {
        guard soundCheck != .off, let rg = song?.replayGain else { return 1 }
        let album = soundCheck == .album && inAlbumOrder
        let db = (album ? rg.albumGain ?? rg.trackGain : rg.trackGain ?? rg.albumGain) ?? rg.fallbackGain
        guard let db, db.isFinite else { return 1 }
        var linear = pow(10, (db + preAmp) / 20)
        let peak = album ? rg.albumPeak ?? rg.trackPeak : rg.trackPeak ?? rg.albumPeak
        if preventClipping, let peak, peak > 0 { linear = min(linear, 1 / peak) }
        return Float(min(linear, 1))
    }
}

/// True when `next` follows `song` on the same album. Such songs often run into each other (live albums, DJ mixes):
/// they are not crossfaded, and Sound Check uses their album gain.
public func isAlbumSequence(_ song: Song?, _ next: Song?) -> Bool {
    guard let song, let next, let album = song.albumId, album == next.albumId, song.id != next.id else { return false }
    let a = (song.discNumber ?? 1, song.track ?? 0), b = (next.discNumber ?? 1, next.track ?? 0)
    return b > a
}
