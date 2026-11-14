import AVFoundation

public extension AVPlayerItem {
    /// Scales the item's audio by `gain` (0…1) through its audio mix: per item, so it changes exactly at
    /// gapless song boundaries. The audio tracks must load first; until then the item plays unscaled.
    @MainActor func setGain(_ gain: Float) async {
        guard gain < 1 else { audioMix = nil; return }
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(gain, at: .zero)
            return parameters
        }
        audioMix = mix
    }
}
