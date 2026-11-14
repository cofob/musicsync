import Device
import Foundation
import Support

/// Local (Mac) directories used by sync. Injectable so tests never touch the real app folders.
public struct SyncLocations: Sendable {
    public var appSupport: URL
    public var caches: URL

    public init(appSupport: URL, caches: URL) {
        self.appSupport = appSupport
        self.caches = caches
    }

    public static var standard: SyncLocations { SyncLocations(appSupport: Paths.appSupport, caches: Paths.caches) }

    public var scrobbleQueue: URL { appSupport.appendingPathComponent("scrobble-queue.json") }

    func directory(_ base: URL, _ components: String...) -> URL {
        let url = components.reduce(base) { $0.appendingPathComponent($1) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func deviceDirectory(key: String) -> URL { directory(appSupport, "devices", key) }
    func backupsDirectory(key: String) -> URL { directory(appSupport, "backups", key) }
    var workDirectory: URL { directory(caches, "work") }
}

public enum DeviceKey {
    /// FirewireGuid hex when known, else the volume UUID.
    public static func resolve(for device: IPodDevice, settings: SyncSettings) -> String {
        FirewireGuid.resolveString(for: device, manualOverride: settings.manualGuids[device.volumeUUID ?? ""])
            ?? device.volumeUUID ?? device.volumeName
    }
}
