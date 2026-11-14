import Foundation

/// "3:45" or "1:02:03".
func formatTime(_ seconds: TimeInterval) -> String {
    let total = Int(min(max(0, seconds.isFinite ? seconds : 0), 1e9))  // a server may send any number
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// A time as VoiceOver should say it: "3 minutes, 5 seconds".
func spokenTime(_ seconds: TimeInterval) -> String {
    let total = Int(min(max(0, seconds.isFinite ? seconds : 0), 1e9))
    return Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
}

/// "58 min" or "2 hr 5 min" for long durations such as albums and playlists.
func formatTotal(_ seconds: Int) -> String {
    let minutes = (seconds + 30) / 60
    return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
}

/// The day of a server date such as "2024-03-05T10:20:00Z", in the short local style; nil when it is not one.
func formatDay(_ iso: String?) -> String? {
    guard let day = iso?.prefix(10), let date = try? Date(String(day), strategy: .iso8601.year().month().day()) else { return nil }
    return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, timeZone: .gmt))
}

/// "1 song" or "12 songs".
func formatSongs(_ count: Int) -> String { "\(count) \(count == 1 ? "song" : "songs")" }

/// "1.2 GB".
/// "0 KB", not the formatter's "Zero kB".
func formatBytes(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file, spellsOutZero: false)) }
