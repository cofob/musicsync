import Playback

/// Window > Equalizer: the filters of every song follow `equalizer` at once, the current song included.
extension Player {
    func equalizerChanged(from old: EqualizerSettings) {
        guard equalizer != old else { return }
        equalizer.save()
        tapChanged()
    }

    /// The tap runs on every song all the time: adding or removing it rebuilds the playing song's audio, which replays
    /// what was buffered (an audible jump back). So turning the equalizer or a visualizer on or off only changes the gains
    /// (flat leaves the samples untouched) and whether the samples are kept. Gapless still joins without a gap with the
    /// tap (`OutputTests.gaplessWithEqualizer`); start and seek take about 0.15 s longer (`Mixer.usesEqualizer`).
    func tapChanged() {
        mixer.usesEqualizer = true
        mixer.equalizer.set(equalizer.isOn ? equalizer.gains : .flat)
        mixer.equalizer.samples.isOn = visualizers > 0
    }
}
