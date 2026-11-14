import Foundation

/// Where long items (podcast episodes, audio books) go on: kept as server bookmarks. Short songs get none.
/// Pure: positions in, decisions out.
public enum ResumePoint {
    /// Items longer than this (10 min) get bookmarks.
    public static let minimumDuration: TimeInterval = 600
    /// Less than this played: nothing worth keeping, and a bookmark this early is not resumed.
    static let start: TimeInterval = 10
    /// Less than this left: the item counts as finished.
    static let end: TimeInterval = 30

    public enum Action: Equatable, Sendable {
        /// Keep the bookmark at this many milliseconds.
        case save(Int)
        /// The item is finished: drop its bookmark.
        case delete
        case none
    }

    /// What to do with the bookmark of an item left at `elapsed` seconds.
    public static func action(elapsed: TimeInterval, duration: TimeInterval) -> Action {
        guard duration > minimumDuration, elapsed.isFinite else { return .none }
        if elapsed >= duration - end { return .delete }
        return elapsed >= start ? .save(Int(elapsed * 1000)) : .none
    }

    /// Second to go on from for a bookmark at `position` milliseconds; nil to play from the start.
    public static func resume(position: Int, duration: TimeInterval) -> TimeInterval? {
        let at = TimeInterval(position) / 1000
        guard duration > minimumDuration, at >= start, at < duration - end else { return nil }
        return at
    }

    /// Part played (0...1) for a progress bar; nil without a usable bookmark.
    public static func progress(position: Int, duration: TimeInterval) -> Double? {
        resume(position: position, duration: duration).map { $0 / duration }
    }
}
