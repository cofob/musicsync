import Playback

/// Window > Equalizer: the filters of every song follow `equalizer` at once, the current song included.
extension Player {
    func equalizerChanged(from old: EqualizerSettings) {
        guard equalizer != old else { return }
        equalizer.save()
        mixer.equalizer.set(equalizer.gains)
        mixer.usesEqualizer = equalizer.isOn
    }
}
