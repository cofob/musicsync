import AVFoundation
import Playback
import Subsonic

/// Mixer cues for queue entries: the downloaded file, else a stream in the chosen quality.
extension Player {
    func cue(at i: Int) -> Mixer.Cue? {
        guard remote == nil else { return nil }
        let gain = gain(at: i)
        switch queue[i] {
        case .file(let url, _, _, _):
            return Self.cue(url, gain: gain)
        case .server(let song):
            if !transcoded.contains(i), let url = localFile?(song.id) { return Self.cue(url, gain: gain) }
            guard let client else { return nil }
            let stream = streamSettings.stream(for: song, fallback: transcoded.contains(i))
            let seeksOnServer = stream.isConverted && supportsTranscodeOffset && settings.transcodeOffset
            return Self.streamCue(song.id, stream, client, gain: gain, from: 0, seeksOnServer: seeksOnServer)
        }
    }

    /// `from` starts a converted stream at that second on the server; such cues seek by loading a new stream,
    /// as converted streams cannot seek themselves.
    private static func streamCue(_ id: String, _ stream: StreamRequest, _ client: SubsonicClient, gain: Float, from: Int,
                                  seeksOnServer: Bool) -> Mixer.Cue {
        let url = client.streamURL(id: id, format: stream.format, maxBitRate: stream.maxBitRate, timeOffset: from > 0 ? from : nil,
                                 estimateContentLength: stream.isConverted)
        // Through `StreamLoader`, so the equalizer and the visualizer get their audio.
        let asset = StreamLoader.asset(url, contentType: stream.contentType)
        var cue = cue(url, gain: gain, contentType: stream.contentType, asset: asset)
        cue.offset = TimeInterval(from)
        if seeksOnServer { cue.reload = { streamCue(id, stream, client, gain: gain, from: Int($0), seeksOnServer: true) } }
        return cue
    }

    private static func cue(_ url: URL, gain: Float, contentType: String? = nil, asset: AVURLAsset? = nil) -> Mixer.Cue {
        let item = AVPlayerItem(asset: asset ?? AVURLAsset(url: url, options: contentType.map { [AVURLAssetOverrideMIMETypeKey: $0] }))
        // Keeps the pitch when the speed is not 1. Spectral raises the peaks off rate 1 (up to +5 dB over full scale, measured).
        item.audioTimePitchAlgorithm = .timeDomain
        return Mixer.Cue(item: item, gain: gain)
    }

    /// Sound Check volume of entry `i`; Album mode uses the album gain when a neighbor in the queue is the same album in order.
    func gain(at i: Int) -> Float {
        let inAlbumOrder = isAlbumSequence(song(at: i - 1), song(at: i)) || isAlbumSequence(song(at: i), song(at: i + 1))
        return settings.gain(for: song(at: i), inAlbumOrder: inAlbumOrder)
    }

    /// AutoMix or crossfade from the current entry into entry `i`, or nil for gapless.
    func transition(to i: Int) -> Transition? {
        guard let index, queue.indices.contains(index) else { return nil }
        return settings.transition(from: song(at: index), to: song(at: i), duration: queue[index].duration,
                                   analyses: analyses(into: i), canSeek: canSeek(i), outgoingRate: Double(mixer.nudge))
    }

    private func song(at i: Int) -> Song? {
        if queue.indices.contains(i), case .server(let song) = queue[i] { song } else { nil }
    }

    func applySpeed() { mixer.rate = Float(settings.speed) }
}
