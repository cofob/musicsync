import AVFoundation
import Playback
import Subsonic

/// Player items for queue entries: the downloaded file, else a stream in the chosen quality.
extension Player {
    func makeItem(_ entry: PlayItem, at i: Int) -> AVPlayerItem? {
        let item: AVPlayerItem
        switch entry {
        case .file(let url, _, _, _):
            item = AVPlayerItem(url: url)
        case .server(let song):
            if !transcoded.contains(i), let url = localFile?(song.id) {
                item = AVPlayerItem(url: url)
            } else {
                guard let client else { return nil }
                let stream = settings.stream(for: song, fallback: transcoded.contains(i))
                let url = client.streamURL(id: song.id, format: stream.format, maxBitRate: stream.maxBitRate)
                item = AVPlayerItem(asset: AVURLAsset(url: url, options: stream.contentType.map { [AVURLAssetOverrideMIMETypeKey: $0] }))
            }
        }
        // Keeps the pitch when the speed is not 1.
        item.audioTimePitchAlgorithm = .spectral
        let gain = gain(at: i)
        Task { await item.setGain(gain) }
        return item
    }

    /// Sound Check volume of entry `i`; Album mode uses the album gain when a neighbor in the queue is the same album in order.
    func gain(at i: Int) -> Float {
        func song(_ i: Int) -> Song? { if queue.indices.contains(i), case .server(let s) = queue[i] { s } else { nil } }
        let inAlbumOrder = isAlbumSequence(song(i - 1), song(i)) || isAlbumSequence(song(i), song(i + 1))
        return settings.gain(for: song(i), inAlbumOrder: inAlbumOrder)
    }

    func applySpeed() {
        player.defaultRate = Float(settings.speed)
        if player.rate != 0 { player.rate = player.defaultRate }
    }
}
