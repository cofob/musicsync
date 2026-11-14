import AppKit
import Device
import ITunesDB
import Observation

/// Owns the connected iPod and a read-only snapshot of its contents.
/// Writes nothing to the iPod except `eject()`.
@MainActor @Observable
final class DeviceModel {
    @ObservationIgnored private let monitor = DeviceMonitor()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    private(set) var devices: [IPodDevice] = []
    /// The device shown in the UI: the picked one, else the first iPod.
    private(set) var current: IPodDevice?
    /// Nil until the first load of `current` finishes.
    private(set) var snapshot: DeviceSnapshot?
    private(set) var isLoading = false
    private(set) var isEjecting = false
    /// Bumped on every new snapshot; cheap change signal for sorted copies.
    private(set) var version = 0

    /// Manual FirewireGuid for a device (from the app settings). Set by `AppModel`.
    @ObservationIgnored var manualGuid: (IPodDevice) -> String? = { _ in nil }

    // MARK: Hooks for the sync UI (later task). Nil / unset = feature not available, UI stays disabled.

    /// Called when the current device is connected, switched or removed (nil).
    @ObservationIgnored var onDeviceChanged: ((IPodDevice?) -> Void)?
    /// Opens the sync flow (selection, plan, progress) for `current`.
    var startSync: (() -> Void)?
    /// Deletes files under `Music/Fxx` that no track references (`snapshot.orphans`).
    var cleanOrphans: (() async -> Void)?
    /// Estimated change of the music size in bytes after the planned sync; drawn in the capacity bar.
    var projectedSyncDelta: Int64?
    /// Set while a sync writes to `current`; eject waits for it. Cover prefetch stops so it does not compete for the disk.
    var isSyncing = false { didSet { if isSyncing { prefetchTask?.cancel() } } }
    private(set) var isScanningOrphans = false

    func start() {
        monitor.start()
        devicesChanged()
        if current == nil { reload() }
        observe()
    }

    /// The last iPod from the Mac caches is shown while no iPod is connected.
    var isOffline: Bool { current == nil && snapshot != nil }

    /// Re-arms itself: `withObservationTracking` fires once per change.
    private func observe() {
        withObservationTracking { _ = monitor.devices } onChange: { [weak self] in
            Task { @MainActor in
                self?.devicesChanged()
                self?.observe()
            }
        }
    }

    func select(_ device: IPodDevice) {
        selectedID = device.id
        devicesChanged()
    }

    @ObservationIgnored private var selectedID: URL?

    private func devicesChanged() {
        devices = monitor.devices
        let next = devices.first { $0.id == selectedID } ?? devices.first
        guard next != current else { return }
        let sameVolume = next?.id == current?.id
        current = next
        // On disconnect the snapshot stays until `reload` replaces it with the offline one.
        if !sameVolume, next != nil { snapshot = nil }
        onDeviceChanged?(next)
        reload()
    }

    /// Reads the iPod again in the background.
    func reload() {
        loadTask?.cancel()
        prefetchTask?.cancel()
        guard let device = current else { return loadOffline() }
        isLoading = true
        let guid = manualGuid(device)
        loadTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                DeviceSnapshot.load(device, manualGuid: guid)
            }.value
            guard !Task.isCancelled, current?.id == device.id else { return }
            self.snapshot = snapshot
            version += 1
            isLoading = false
            if snapshot.database != nil {
                let last = LastDevice(snapshot)
                Task.detached(priority: .utility) { last.save() }
            }
            if let artwork = snapshot.artwork, !isSyncing {
                prefetchTask = Task(priority: .utility) { await artwork.prefetchAll() }
            }
        }
    }

    private func loadOffline() {
        isLoading = false
        loadTask = Task {
            let offline = await Task.detached(priority: .utility) { LastDevice.load().flatMap(DeviceSnapshot.offline) }.value
            guard !Task.isCancelled, current == nil else { return }
            snapshot = offline
            version += 1
        }
    }

    /// Finds files in `Music/Fxx` that no track references; fills `snapshot.orphans`.
    func scanOrphans() {
        guard let s = snapshot, let db = s.database, !isScanningOrphans else { return }
        isScanningOrphans = true
        let device = s.device, referenced = Set(db.tracks.map(\.location)), seen = version
        Task {
            let found = await Task.detached(priority: .utility) { try? device.layout.orphans(referenced: referenced) }.value
            isScanningOrphans = false
            guard version == seen, let found else { return }
            snapshot?.orphans = .init(count: found.count, bytes: found.reduce(0) { $0 + $1.size })
        }
    }

    func eject() async throws {
        guard let device = current, !isEjecting, !isSyncing else { return }
        isEjecting = true
        defer { isEjecting = false }
        try await device.eject()
        monitor.rescan()
    }

    /// Queue entries for local playback of iPod files.
    func playItems(_ tracks: [DeviceTrack]) -> [PlayItem] {
        guard let root = current?.mountURL else { return [] }
        return tracks.map {
            .file(root.appendingPathComponent($0.path), title: $0.title, artist: $0.artist.nilIfEmpty, album: $0.album.nilIfEmpty)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
