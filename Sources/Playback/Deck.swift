import AVFoundation

/// One of the two players of the `Mixer`. Songs that play gapless follow each other in its queue; a crossfade
/// starts the next song on the other deck. Its volume is the mixer volume times the transition fade.
@MainActor final class Deck {
    let player = AVQueuePlayer()
    weak var mixer: Mixer?
    var volume: Float = 1 { didSet { applyVolume() } }
    /// Transition volume, 0…1.
    var fade: Float = 1 { didSet { applyVolume() } }
    private var observation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var boundaryObserver: Any?

    /// Tests and dev runs with MUSICSYNC_MUTE=1 never reach the speakers, whatever the volume is set to.
    /// Volume 0, not `isMuted`: the equalizer tap still sees the full signal, so output measures keep working.
    static let silent = ProcessInfo.processInfo.environment["MUSICSYNC_MUTE"] == "1"
        || ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName)

    init() {
        applyVolume()
        observation = player.observe(\.currentItem) { [weak self] _, _ in
            Task { @MainActor in if let self { self.mixer?.itemChanged(self) } }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.mixer?.tick(self) } }
        }
    }

    private func applyVolume() { player.volume = Self.silent ? 0 : volume * fade }

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
        guard let time, time > 0, time.isFinite else { return }
        let times = [NSValue(time: CMTime(seconds: time, preferredTimescale: 600))]
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { if let self { self.mixer?.tick(self) } }
        }
    }

    /// Host time at which the playing item reaches `time`. When that is less than `margin` away (a late call, e.g. from a
    /// busy main thread), the host time `margin` from now and how far past `time` the item is then. Nil when the item
    /// does not run, or `time` is a second away.
    func hostTime(at time: TimeInterval, margin: TimeInterval) -> (host: CMTime, late: TimeInterval)? {
        guard let timebase = player.currentItem?.timebase, CMTimebaseGetRate(timebase) > 0 else { return nil }
        let clock = CMClockGetHostTimeClock()
        let host = CMSyncConvertTime(CMTime(seconds: time, preferredTimescale: 1_000_000), from: timebase, to: clock)
        let soon = CMClockGetTime(clock) + CMTime(seconds: margin, preferredTimescale: 1_000_000)
        guard host.isNumeric, (host - soon).seconds < 1 - margin else { return nil }
        guard host < soon else { return (host, 0) }
        return (soon, CMSyncConvertTime(soon, from: clock, to: timebase).seconds - time)
    }

    /// Starts the paused item at `rate`: from `time` at `hostTime` when given, to line up with the other deck, else now.
    /// A timed start needs the player not to wait for buffering; `clear()` and the end of the fade turn that back on.
    func start(rate: Float, at hostTime: CMTime?, from time: TimeInterval) {
        guard let hostTime else { player.rate = rate; return }
        player.automaticallyWaitsToMinimizeStalling = false
        // An earlier seek to `time` may still run; a new one only when the item is not there.
        let itemTime = abs(self.time - time) < 0.001 ? CMTime.invalid : CMTime(seconds: time, preferredTimescale: 1_000_000)
        player.setRate(rate, time: itemTime, atHostTime: hostTime)
    }

    /// Also cancels a timed start, which a plain pause does not always do.
    func pause() {
        if !player.automaticallyWaitsToMinimizeStalling { player.setRate(0, time: .invalid, atHostTime: .invalid) }
        player.pause()
    }

    func clear() {
        pause()
        player.automaticallyWaitsToMinimizeStalling = true
        player.removeAllItems()
        setBoundary(nil)
        fade = 1
    }
}
