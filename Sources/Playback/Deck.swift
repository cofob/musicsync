import AVFoundation

/// One of the two players of the `Mixer`. Songs that play gapless follow each other in its queue; a crossfade
/// starts the next song on the other deck. Its volume is the mixer volume times the transition fade.
@MainActor final class Deck {
    let player = AVQueuePlayer()
    weak var mixer: Mixer?
    var volume: Float = 1 { didSet { player.volume = volume * fade } }
    /// Transition volume, 0…1.
    var fade: Float = 1 { didSet { player.volume = volume * fade } }
    private var observation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var boundaryObserver: Any?

    init() {
        observation = player.observe(\.currentItem) { [weak self] _, _ in
            Task { @MainActor in if let self { self.mixer?.itemChanged(self) } }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.mixer?.tick(self) } }
        }
    }

    /// Time in the current item.
    var time: TimeInterval {
        let t = player.currentTime().seconds
        return t.isFinite ? max(t, 0) : 0
    }

    /// Length of the current item, once known.
    var duration: TimeInterval? {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return nil }
        return d
    }

    /// Calls the mixer when the current item reaches `time`, more exactly than the periodic tick; nil removes it.
    func setBoundary(_ time: TimeInterval?) {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        guard let time, time > 0 else { return }
        let times = [NSValue(time: CMTime(seconds: time, preferredTimescale: 600))]
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { if let self { self.mixer?.tick(self) } }
        }
    }

    func clear() {
        player.pause()
        player.removeAllItems()
        setBoundary(nil)
        fade = 1
    }
}
