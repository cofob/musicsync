import Foundation
import Subsonic

/// Volume shape of a transition.
public enum FadeCurve: Sendable {
    case linear
    /// Keeps the loudness about even through the overlap.
    case equalPower

    /// Volumes of the outgoing and the incoming song at `progress` 0…1.
    public func volumes(at progress: Double) -> (out: Double, in: Double) {
        let p = min(max(progress, 0), 1)
        switch self {
        case .linear: return (1 - p, p)
        case .equalPower: return (cos(p * .pi / 2), sin(p * .pi / 2))
        }
    }
}

/// How one song hands over to the next: when the outgoing song reaches `at`, the incoming one starts at `offset`,
/// and over `duration` seconds the volumes follow `curve`.
public struct Transition: Equatable, Sendable {
    /// Time in the outgoing song.
    public var at: TimeInterval
    /// Start time in the incoming song.
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var curve: FadeCurve
    /// Rate of the incoming song, e.g. for beat matching; it keeps it to its end. 1 keeps the tempo.
    public var rate: Float

    public init(at: TimeInterval, offset: TimeInterval = 0, duration: TimeInterval, curve: FadeCurve = .equalPower, rate: Float = 1) {
        self.at = at
        self.offset = offset
        self.duration = duration
        self.curve = curve
        self.rate = rate
    }
}

public extension PlaybackSettings {
    /// Crossfade from `song` into `next`, or nil to play them gapless. `duration` is the length of `song`.
    func transition(from song: Song?, to next: Song?, duration: TimeInterval?) -> Transition? {
        guard transitions != .off, let duration, duration > 2, song?.id != next?.id, !isAlbumSequence(song, next) else { return nil }
        let fade = min(min(max(crossfadeSeconds, 1), 12), duration / 2)
        return Transition(at: duration - fade, duration: fade)
    }
}
