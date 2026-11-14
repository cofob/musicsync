import Foundation

/// Stops playback after a time or at the end of the current song.
public enum SleepTimer: Hashable, Sendable {
    case minutes(Int)
    case endOfSong

    public static let choices: [SleepTimer] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfSong]

    /// When playback stops, for a timer set at `start`; nil for `endOfSong`.
    public func deadline(from start: Date) -> Date? {
        if case .minutes(let m) = self { start.addingTimeInterval(TimeInterval(m * 60)) } else { nil }
    }

    public var title: String {
        switch self {
        case .minutes(let m): "\(m) Minutes"
        case .endOfSong: "End of Current Song"
        }
    }
}
