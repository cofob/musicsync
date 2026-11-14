import Foundation
import Playback
import Subsonic

/// Settings > Playback, the sleep timer and the server features the player uses.
extension Player {
    func settingsChanged(from old: PlaybackSettings) {
        guard settings != old else { return }
        settings.save()
        applySpeed()
        if let index { mixer.setGain(gain(at: index)) }
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

    func pause() { if isPlaying { toggle() } }

    /// Reads the server extensions the player uses. A network failure tries again later, so one bad moment at
    /// connect does not turn the feature off for the whole session; a server that answers with an error has none.
    func loadFeatures(_ client: SubsonicClient) async {
        supportsTranscodeOffset = false
        for delay in [0, 5, 30, 120, 600] {
            guard (try? await Task.sleep(for: .seconds(delay))) != nil, client.baseURL == self.client?.baseURL else { return }
            let names: [String]
            do { names = try await client.getOpenSubsonicExtensions().map(\.name) } catch SubsonicError.api { return } catch { continue }
            guard client.baseURL == self.client?.baseURL else { return }
            supportsTranscodeOffset = names.contains("transcodeOffset")
            return
        }
    }
}
