import Network
import Playback
import Subsonic

/// Streaming quality by network: Settings > Playback can pick a lower one for metered networks.
extension Player {
    private static let monitor = NWPathMonitor()

    /// Settings with the quality of the current network.
    var streamSettings: PlaybackSettings { settings.network(metered: isMetered) }

    /// What the current song plays as: "Downloaded", "Original", "MP3 128 kbps"; nil for local files and the jukebox.
    var activeQuality: String? {
        guard remote == nil, let index, case .server(let song) = current else { return nil }
        if !transcoded.contains(index), localFile?(song.id) != nil { return "Downloaded" }
        return streamSettings.stream(for: song, fallback: transcoded.contains(index)).title
    }

    func watchNetwork() {
        Self.monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isConstrained || path.isExpensive
            Task { @MainActor in self?.isMetered = metered }
        }
        Self.monitor.start(queue: .global(qos: .utility))
    }
}
