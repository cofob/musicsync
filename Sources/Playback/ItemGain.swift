import AVFoundation

public extension AVPlayerItem {
    /// Scales the item's audio by `gain` (0…1) through its audio mix: per item, so it changes exactly at
    /// gapless song boundaries. The audio tracks must load first; until then the item plays unscaled.
    /// `equalizer` adds its tap to each track; an item without audio tracks (live HLS) plays without it.
    @MainActor func setGain(_ gain: Float, equalizer: Equalizer? = nil) async {
        guard gain < 1 || equalizer != nil else { audioMix = nil; return }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(gain, at: .zero)
            parameters.audioTapProcessor = equalizer?.makeTap(for: self)
            return parameters
        }
        audioMix = mix
    }
}
