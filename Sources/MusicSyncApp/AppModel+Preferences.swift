import Foundation
import Library
import Playback
import Preferences
import Support
import Sync

/// Actions of Settings > Library and Settings > Advanced.
extension AppModel {
    /// Covers of all servers (`CoverArtCache` keeps one folder per account below it).
    nonisolated static var coverCacheDirectory: URL { Paths.caches("covers") }

    /// The iPod name from Settings > Sync when the iPod's database has another one.
    var deviceRename: String? {
        guard let uuid = ipod.current?.volumeUUID, let snapshot = ipod.snapshot, snapshot.locations != nil,
              let name = syncSettings.deviceNames[uuid]?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name != snapshot.name else { return nil }
        return name
    }

    /// Deletes the local play history; mixes, stations and Your Stats start over.
    func clearHistory() async {
        guard let library else { return }
        do { try await library.history.clear() } catch { return report(error) }
        await mixes.load(refresh: true)
    }

    func coverCacheSize() async -> Int64 {
        await Task.detached(priority: .utility) { DiskCache.size(of: Self.coverCacheDirectory) }.value
    }

    /// Keeps the cover cache under the limit of Settings > Advanced.
    func trimCoverCache() {
        guard let limit = AppPreferences.shared.advanced.coverCacheBytes else { return }
        Task.detached(priority: .utility) { DiskCache.trim(Self.coverCacheDirectory, to: limit) }
    }

    func clearCoverCache() async {
        await Task.detached(priority: .utility) { DiskCache.clear(Self.coverCacheDirectory) }.value
    }

    /// Settings > Advanced > Reset All Settings. The server, paired remotes and iPod GUIDs stay.
    /// Options of the other pages that are not reset here return to defaults at the next launch.
    func resetAllSettings() {
        let guids = syncSettings.manualGuids
        SettingsReset.reset(.app, keeping: ["serverConfig", "remoteDevices", "lastSyncDevice", "guideShown"])
        AppPreferences.shared.reset()
        var sync = SyncSettings()
        sync.manualGuids = guids
        syncSettings = sync
        mirrorSettings = MirrorSettings()
        player.settings = PlaybackSettings()
        player.equalizer = EqualizerSettings()
    }
}
