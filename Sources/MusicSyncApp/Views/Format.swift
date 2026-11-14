import Foundation

/// "3:45" or "1:02:03".
func formatTime(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// "58 min" or "2 hr 5 min" for long durations such as albums and playlists.
func formatTotal(_ seconds: Int) -> String {
    let minutes = (seconds + 30) / 60
    return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
}

/// "1.2 GB".
/// "0 KB", not the formatter's "Zero kB".
func formatBytes(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file, spellsOutZero: false)) }
