import Foundation

/// Part of the day, for "songs you play at this time".
public enum DayPart: Int, Sendable, CaseIterable {
    case morning, afternoon, evening, night

    /// Morning 5–11, afternoon 11–17, evening 17–22, night 22–5.
    public init(hour: Int) {
        switch hour {
        case 5..<11: self = .morning
        case 11..<17: self = .afternoon
        case 17..<22: self = .evening
        default: self = .night
        }
    }

    /// "in the Evening", "at Night".
    public var phrase: String {
        switch self {
        case .morning: "in the Morning"
        case .afternoon: "in the Afternoon"
        case .evening: "in the Evening"
        case .night: "at Night"
        }
    }
}

/// When the listener plays what: completed plays of the last 90 days that fall in the same part of the day,
/// and on the same kind of day (weekday or weekend), as `now`.
struct ListeningContext: Sendable {
    let part: DayPart
    /// Per song: plays in this part of the day, and plays on this kind of day.
    let inPart: [String: Int]
    let onDay: [String: Int]
    /// Completed plays per song in the same 90 days.
    let plays: [String: Int]

    init(_ events: [PlayEvent], now: Date, calendar: Calendar) {
        part = DayPart(hour: calendar.component(.hour, from: now))
        let weekend = calendar.isDateInWeekend(now)
        var inPart: [String: Int] = [:], onDay: [String: Int] = [:], plays: [String: Int] = [:]
        for event in events where event.completed && now.timeIntervalSince(event.startedAt) < 90 * 86400 {
            plays[event.songId, default: 0] += 1
            if DayPart(hour: calendar.component(.hour, from: event.startedAt)) == part { inPart[event.songId, default: 0] += 1 }
            if calendar.isDateInWeekend(event.startedAt) == weekend { onDay[event.songId, default: 0] += 1 }
        }
        self.inPart = inPart
        self.onDay = onDay
        self.plays = plays
    }

    /// 0...1.5: how much of a song's listening happens at times like now; the part of the day counts twice
    /// as much as the kind of day. Few plays say less (+2 in the divisor).
    func score(_ id: String) -> Double {
        (Double(inPart[id] ?? 0) + 0.5 * Double(onDay[id] ?? 0)) / Double((plays[id] ?? 0) + 2)
    }
}
