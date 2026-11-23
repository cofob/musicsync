import Playback

/// Window > Equalizer: the filters of every song follow `equalizer` at once, the current song included.
extension Player {
    func equalizerChanged(from old: EqualizerSettings) {
        guard equalizer != old else { return }
        equalizer.save()
        mixer.equalizer.set(equalizer.gains)
        tapChanged()
    }

    /// The tap runs for the equalizer and for visible visualizers; only the visualizers need its samples.
    func tapChanged() {
        mixer.usesEqualizer = equalizer.isOn || visualizers > 0
        mixer.equalizer.samples.isOn = visualizers > 0
    }
}
