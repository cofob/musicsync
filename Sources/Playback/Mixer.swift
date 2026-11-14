import AVFoundation

/// Plays songs on two decks: gapless in one deck, or from one deck into the other along a `Transition`
/// (crossfade now; beat-matched mixes can use the same path). The caller owns the queue: the mixer only
/// knows the current song and the next one, and reports what happens through `onEvent`.
@MainActor public final class Mixer {
    /// One song as the mixer plays it.
    public struct Cue {
        public let item: AVPlayerItem
        /// Sound Check volume, 0…1.
        public var gain: Float
        /// Time in the song at which `item` starts (a stream that the server starts later).
        public var offset: TimeInterval
        /// Builds a cue that starts at a time; set for streams that cannot seek themselves (OpenSubsonic `transcodeOffset`).
        public var reload: (@MainActor (TimeInterval) -> Cue?)?

        public init(item: AVPlayerItem, gain: Float = 1, offset: TimeInterval = 0, reload: (@MainActor (TimeInterval) -> Cue?)? = nil) {
            self.item = item
            self.gain = gain
            self.offset = offset
            self.reload = reload
        }
    }

    public enum Event: Equatable, Sendable {
        /// The next song became the current one: gapless, at the start of a transition, or by `skipToNext` (`skipped`).
        case advanced(skipped: Bool)
        /// The current or the next song is ready to play.
        case ready
        /// The current or the next song cannot play; a failed next song is dropped.
        case failed(current: Bool, message: String?)
        /// The current song played to its end and no next song was set.
        case ended
        /// `isPlaying` changed.
        case playing(Bool)
    }

    public var onEvent: @MainActor (Event) -> Void = { _ in }
    /// About twice a second while playing: the time in the current song.
    public var onTime: @MainActor (TimeInterval) -> Void = { _ in }
    public var volume: Float = 1 { didSet { decks.forEach { $0.volume = volume } } }
    /// Playback speed; items keep their pitch through their `audioTimePitchAlgorithm`.
    public var rate: Float = 1 { didSet { applyRate() } }
    /// Play was asked for and not paused since.
    public private(set) var isPlaying = false { didSet { if isPlaying != oldValue { onEvent(.playing(isPlaying)) } } }
    public var hasCurrent: Bool { current != nil }
    /// Time in the current song.
    public var time: TimeInterval { decks[active].time + (current?.offset ?? 0) }
    /// Length of the current song from its file, once known.
    public var duration: TimeInterval? { decks[active].duration.map { $0 + (current?.offset ?? 0) } }
    /// A transition is running: two songs play.
    public var isFading: Bool { fade != nil }
    /// Runs on every song through its audio mix while `usesEqualizer` is on.
    public let equalizer: Equalizer
    /// The equalizer tap delays the start of a song and of a seek, so songs get it only when it is on.
    /// Measured on local files: start and seek take 0.30 and 0.26 s with an empty PostEffects tap, against
    /// 0.15 and 0.13 s with no tap (0.51 s with PreEffects); the same when the mix is set before the item is queued,
    /// with `preroll` or without waiting to minimize stalling. A change rebuilds the mix of the current and the next song.
    public var usesEqualizer = false {
        didSet {
            guard usesEqualizer != oldValue else { return }
            for cue in [current, next].compactMap({ $0 }) { Task { await cue.item.setGain(cue.gain, equalizer: tap) } }
            if let next, transition == nil || transition?.duration == 0 { setNext(next) }
        }
    }
    private var tap: Equalizer? { usesEqualizer ? equalizer : nil }
    /// Items with an audio tap do not play gapless in one queue (measured: 0.18–0.32 s of silence between them), so with
    /// the equalizer on a gapless next song starts on the other deck at the end of the current one, once its length is known.
    private var cut: Transition { Transition(at: .infinity, duration: 0) }

    let decks = [Deck(), Deck()]
    /// Deck of the current song.
    private var active = 0
    private var idle: Deck { decks[1 - active] }
    private var current: Cue?
    private var next: Cue?
    /// How `next` starts; nil plays it gapless after `current`.
    private var transition: Transition?
    /// The running transition, the deck that fades out and its `nudge`.
    private var fade: (outgoing: Deck, transition: Transition, nudge: Float)?
    private var fadeTimer: Timer?
    private var statusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// The next item still has to seek to the transition offset once it is ready.
    private var seekPending = false
    /// The incoming deck is started this early, paused, to begin at the exact host time of the transition.
    static let lead: TimeInterval = 0.3
    /// Rate factor of the current song from a beat-matched transition. It stays until the song ends: each rate
    /// change of a playing item silences it for 0.1–0.2 s (measured), so easing it back in steps cut out the sound.
    public private(set) var nudge: Float = 1

    public init(equalizer: Equalizer = Equalizer()) {
        self.equalizer = equalizer
        decks.forEach { $0.mixer = self }
    }

    // MARK: Control

    /// Drops everything and plays `cue` from its start.
    public func play(_ cue: Cue, paused: Bool = false) {
        reset()
        current = cue
        isPlaying = !paused
        observe(cue.item)
        let deck = decks[active]
        deck.player.insert(cue.item, after: nil)
        // The gain is set before the first sound.
        Task {
            await cue.item.setGain(cue.gain, equalizer: tap)
            if isPlaying, current?.item === cue.item { deck.player.rate = rate }
        }
    }

    /// Sets the song after the current one; nil clears it. A gapless next song is queued on the current deck,
    /// a song with a transition is loaded paused on the other deck.
    public func setNext(_ cue: Cue?, transition: Transition? = nil) {
        dropNext()
        next = cue
        self.transition = transition ?? (usesEqualizer ? cut : nil)
        guard let cue else { return }
        observe(cue.item)
        Task { await cue.item.setGain(cue.gain, equalizer: tap) }
        loadNext()
    }

    /// Changes how the next song starts, e.g. when its analysis came in after it was loaded.
    /// A gapless next song stays gapless, and a running transition is kept, as is the old one when the new one is due already.
    public func retime(_ transition: Transition) {
        guard let next, fade == nil, let old = self.transition, old != transition, transition.at - Self.lead > time + 0.2 else { return }
        self.transition = transition
        if idle.player.currentItem === next.item, old.offset != transition.offset {
            seekPending = true
            if next.item.status == .readyToPlay { itemStatusChanged(next.item) }
        }
        setBoundary()
    }

    /// Starts the next song now, without a transition. False when there is none.
    public func skipToNext() -> Bool {
        guard current != nil, next != nil else { return false }
        finishFade()
        loadNext()
        guard let next else { return false }
        if transition != nil {
            decks[active].clear()
            active = 1 - active
            nudge = 1
            if isPlaying { decks[active].player.rate = rate }
        } else {
            decks[active].player.advanceToNextItem()
        }
        advance(to: next, skipped: true)
        return true
    }

    public func pause() {
        isPlaying = false
        decks.forEach { $0.pause() }
    }

    public func resume() {
        guard current != nil else { return }
        isPlaying = true
        applyRate()
    }

    public func seek(to time: TimeInterval) {
        guard let current else { return }
        finishFade()
        let deck = decks[active]
        if var cue = current.reload?(time) {
            cue.gain = current.gain
            self.current = cue
            observe(cue.item)
            prune()
            deck.player.insert(cue.item, after: deck.player.currentItem)
            deck.player.advanceToNextItem()
            Task { await cue.item.setGain(cue.gain, equalizer: tap) }
        } else {
            deck.player.seek(to: CMTime(seconds: max(0, time - current.offset), preferredTimescale: 600))
        }
        setBoundary()
    }

    /// Changes the Sound Check volume of the current song.
    public func setGain(_ gain: Float) {
        guard let item = current?.item else { return }
        current?.gain = gain
        Task { await item.setGain(gain, equalizer: tap) }
    }

    public func stop() {
        reset()
        isPlaying = false
    }

    // MARK: Deck events

    func itemChanged(_ deck: Deck) {
        if let fade, deck === fade.outgoing {
            if deck.player.currentItem == nil { finishFade() }
            return
        }
        guard deck === decks[active], current != nil else { return }
        let item = deck.player.currentItem
        if let next, transition == nil, item === next.item {
            advance(to: next)
        } else if item == nil, fade == nil {
            // The next song did not start in time (still loading, or dropped by the deck): start it now.
            if let next, transition != nil {
                startTransition(next)
                finishFade()
            } else if let next {
                deck.player.insert(next.item, after: nil)
                if isPlaying { deck.player.rate = rate }
                advance(to: next)
            } else {
                current = nil
                isPlaying = false
                onEvent(.ended)
            }
        }
    }

    func tick(_ deck: Deck) {
        guard deck === decks[active], current != nil else { return }
        onTime(time)
        loadNext()
        if transition == cut, let duration {
            transition?.at = duration
            setBoundary()
        }
        guard fade == nil, isPlaying, let next, let transition, next.item.status == .readyToPlay else { return }
        var at = transition.at
        if let duration { at = min(at, duration - transition.duration) }
        // The boundary call can come a little before its time.
        if time >= at - Self.lead - 0.05 { startTransition(next, at: at) }
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            if item === current?.item || item === next?.item { onEvent(.ready) }
            if item === next?.item, seekPending, let next, let transition {
                seekPending = false
                let time = CMTime(seconds: max(0, transition.offset - next.offset), preferredTimescale: 600)
                item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
            }
        case .failed:
            let message = item.error?.localizedDescription
            if item === current?.item {
                onEvent(.failed(current: true, message: message))
            } else if item === next?.item {
                dropNext()
                onEvent(.failed(current: false, message: message))
            }
        default: break
        }
    }

    // MARK: Transitions

    /// `at`, the time in the current song, starts the incoming deck when the current one gets there, to the sample.
    private func startTransition(_ next: Cue, at: TimeInterval? = nil) {
        guard let transition else { return }
        loadIdle(next.item)
        let outgoing = decks[active]
        let start = at.flatMap { outgoing.hostTime(at: $0 - (current?.offset ?? 0)) }
        outgoing.setBoundary(nil)
        active = 1 - active
        let incoming = decks[active]
        let volumes = transition.duration > 0 ? transition.curve.volumes(at: 0) : (out: 1, in: 1)
        outgoing.fade = Float(volumes.out)
        incoming.fade = Float(volumes.in)
        fade = (outgoing, transition, nudge)
        nudge = transition.rate
        if isPlaying { incoming.start(rate: rate * nudge, at: start, from: max(0, transition.offset - next.offset)) }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFade() }
        }
        advance(to: next)
    }

    /// Volumes follow the incoming song's time, so a pause or a stall holds the fade.
    private func stepFade() {
        guard let fade else { return }
        let t = fade.transition
        // A cut ends once the incoming song runs.
        let progress = t.duration > 0 ? (time - t.offset) / (t.duration * Double(t.rate)) : time > t.offset ? 1 : 0
        guard progress < 1, fade.outgoing.player.currentItem != nil else { return finishFade() }
        let volumes = t.curve.volumes(at: progress)
        fade.outgoing.fade = Float(volumes.out)
        decks[active].fade = Float(volumes.in)
    }

    /// Ends the running transition at once: the outgoing song stops, the current one plays at full volume.
    private func finishFade() {
        guard let fade else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        self.fade = nil
        fade.outgoing.clear()
        decks[active].fade = 1
        decks[active].player.automaticallyWaitsToMinimizeStalling = true
        loadNext()
    }

    // MARK: State

    private func advance(to next: Cue, skipped: Bool = false) {
        current = next
        self.next = nil
        transition = nil
        seekPending = false
        prune()
        setBoundary()
        onEvent(.advanced(skipped: skipped))
    }

    /// Puts `next` where it plays from, unless it is there. During a transition the other deck still fades out;
    /// it loads afterwards. Called again on every tick: a deck can drop an item on its own after a failed one.
    private func loadNext() {
        guard let next, current != nil else { return }
        guard let transition else {
            if !decks[active].player.items().contains(next.item) { decks[active].player.insert(next.item, after: nil) }
            return
        }
        guard fade == nil, idle.player.currentItem !== next.item else { return }
        loadIdle(next.item)
        seekPending = transition.offset > next.offset
        if seekPending, next.item.status == .readyToPlay { itemStatusChanged(next.item) }
        setBoundary()
    }

    /// Makes `item` the paused current item of the idle deck.
    private func loadIdle(_ item: AVPlayerItem) {
        guard idle.player.currentItem !== item else { return }
        idle.clear()
        idle.player.insert(item, after: nil)
    }

    private func dropNext() {
        guard let next else { return }
        if transition == nil {
            decks[active].player.remove(next.item)
        } else if fade == nil {
            idle.clear()
        }
        self.next = nil
        transition = nil
        seekPending = false
        prune()
        setBoundary()
    }

    /// Wakes the current deck when the transition is due.
    private func setBoundary() {
        decks[active].setBoundary(fade == nil ? transition.map { $0.at - Self.lead - (current?.offset ?? 0) } : nil)
    }

    private func applyRate() {
        guard isPlaying else { return }
        decks[active].player.rate = rate * nudge
        if let fade { fade.outgoing.player.rate = rate * fade.nudge }
    }

    private func reset() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fade = nil
        nudge = 1
        decks.forEach { $0.clear() }
        current = nil
        next = nil
        transition = nil
        seekPending = false
        statusObservations = [:]
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.initial]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        }
    }

    /// Stops watching items that are neither current nor next.
    private func prune() {
        let live = Set([current?.item, next?.item].compactMap { $0.map(ObjectIdentifier.init) })
        statusObservations = statusObservations.filter { live.contains($0.key) }
    }
}
