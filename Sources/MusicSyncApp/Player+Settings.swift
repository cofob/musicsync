import Foundation
import Playback
import Subsonic

/// Settings > Playback, the sleep timer and the server features the player uses.
extension Player {
    func settingsChanged(from old: PlaybackSettings) {
        guard settings != old else { return }
        settings.save()
        applySpeed()
        if let index, let item = player.currentItem { Task { await item.setGain(gain(at: index)) } }
        // Quality, crossfade or gain changed: the preloaded next song is built again.
        if settings.speed == old.speed { resetUpcoming() }
    }

    func sleepTimerChanged() {
        sleepTask?.cancel()
        if let deadline = sleepTimer?.deadline(from: Date()) {
            sleepTask = Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))) != nil else { return }
                self?.sleepTimer = nil
                self?.pause()
            }
        }
        // End of song: nothing is preloaded, so playback stops when the song ends.
        resetUpcoming()
    }

    /// Called when the last song played to its end.
    func ended() {
        if sleepTimer == .endOfSong { sleepTimer = nil }
    }

    func pause() { if isPlaying { toggle() } }

    /// Reads the server extensions the player uses.
    func loadFeatures(_ client: SubsonicClient) async {
        supportsTranscodeOffset = false
        let names = (try? await client.getOpenSubsonicExtensions())?.map(\.name) ?? []
        guard client.baseURL == self.client?.baseURL else { return }
        supportsTranscodeOffset = names.contains("transcodeOffset")
    }
}
