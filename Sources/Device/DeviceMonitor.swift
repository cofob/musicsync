import AppKit
import Observation

/// Keeps `devices` in sync with mounted volumes.
@MainActor @Observable
public final class DeviceMonitor {
    public private(set) var devices: [IPodDevice] = []

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init() {}

    public func start() {
        guard tasks.isEmpty else { return }
        rescan()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            tasks.append(Task { [weak self] in
                for await _ in center.notifications(named: name).map({ _ in () }) { self?.rescan() }
            })
        }
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// Reads the volumes off the main thread: a busy iPod disk must not stall the UI.
    public func rescan() {
        scanTask?.cancel()
        scanTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                let volumes = FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
                return volumes.compactMap(IPodDevice.detect(at:))
            }.value
            guard !Task.isCancelled else { return }
            if found != devices { devices = found }
            Task.detached(priority: .utility) { found.forEach { $0.disableSpotlight() } }
        }
    }
}
