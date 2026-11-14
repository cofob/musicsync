import Device
import Foundation
import Observation
import Subsonic
import Sync

/// Selection, album statuses, plan preview and the running sync for the current iPod.
@MainActor @Observable
final class SyncModel {
    struct Item: Identifiable {
        let id: String
        let title: String
        var stage: ItemStage
    }

    /// One sync, from start to summary.
    struct Run {
        var phase = SyncPhase.preparing
        var progress: SyncProgress?
        var items: [Item] = []
        var warnings: [String] = []
        var summary: SyncSummary?
        var error: String?
        var cancelling = false

        var isFinished: Bool { summary != nil || error != nil }
        var fraction: Double {
            guard let p = progress else { return 0 }
            return p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : Double(p.itemsDone) / Double(max(p.itemsTotal, 1))
        }
    }

    /// The selection expanded and diffed against the device.
    struct Preview {
        let plan: SyncPlan
        let warnings: [String]
        /// Stock firmware tracks change but the FireWire GUID is unknown.
        let needsGuid: Bool
        /// A `Play Counts` file waits: a sync merges it and sends scrobbles even without track changes.
        let hasPlayCounts: Bool

        var canRun: Bool { plan.fits && !needsGuid && (!plan.isEmpty || hasPlayCounts) }
    }

    /// Current device, else the last one seen; nil hides all sync controls.
    private(set) var deviceKey: String?
    private(set) var selection = Selection()
    private(set) var preview: Preview?
    private(set) var previewError: String?
    private(set) var isPlanning = false
    /// Albums resolved while planning, for "Checking 40 of 120 albums…".
    var checked: (done: Int, total: Int)?
    /// Nil until there is more than one album to check.
    var checkingText: String? { checked.flatMap { $0.total > 1 ? "Checking \($0.done) of \($0.total) albums…" : nil } }
    @ObservationIgnored private var planID = 0
    private(set) var run: Run?
    var showSheet = false
    /// Album the user asked to sync that iTunes already put on the iPod; waits for confirmation.
    var foreignAlbum: Album?
    var confirmCleanUp = false
    /// Tracks the user asked to delete from the iPod; waits for confirmation.
    var tracksToDelete: [DeviceTrack] = []

    private var context: Context?
    private var matcher: Matcher?

    private struct Context: Sendable {
        let manifest: Manifest
        let library: DeviceLibrary
        let warning: String?
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let locations: SyncLocations
    @ObservationIgnored private let scrobbler: Scrobbler
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var expander: SelectionExpander?
    @ObservationIgnored private var itemIndex: [String: Int] = [:]
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    private static let lastDeviceKey = "lastSyncDevice"

    init() {
        locations = .standard
        scrobbler = .shared
        engine = SyncEngine(locations: locations, scrobbler: scrobbler)
    }

    func attach(_ app: AppModel) {
        self.app = app
        if let key = UserDefaults.app.string(forKey: Self.lastDeviceKey) { setKey(key) }
    }

    var isAvailable: Bool { deviceKey != nil }
    var isRunning: Bool { run.map { !$0.isFinished } ?? false }

    // MARK: Device and library

    /// Reads the manifest and device database again; call after the iPod snapshot changed.
    func deviceUpdated() {
        contextTask?.cancel()
        guard let app, let device = app.ipod.current else {
            context = nil
            updateMatcher()
            schedulePlan()
            return
        }
        setKey(DeviceKey.resolve(for: device, settings: app.syncSettings))
        let serverKey = app.client?.serverKey ?? ""
        contextTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Context, Error> in
                let (manifest, warning) = ManifestStore.load(for: device, serverKey: serverKey)
                return Result { Context(manifest: manifest, library: try DeviceLibrary.load(device: device, manifest: manifest), warning: warning) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let context): self.context = context
            case .failure(let error): self.context = nil; previewError = "Cannot read the iPod: \(error.localizedDescription)"
            }
            updateMatcher()
            schedulePlan()
        }
    }

    /// Server data changed: drop cached albums and plan again.
    func libraryChanged() {
        expander = nil
        schedulePlan()
    }

    private func setKey(_ key: String) {
        guard key != deviceKey else { return }
        deviceKey = key
        selection = SelectionStore(locations: locations).load(deviceKey: key)
        UserDefaults.app.set(key, forKey: Self.lastDeviceKey)
    }

    private func updateMatcher() {
        guard let context, let app else { matcher = nil; return }
        matcher = Matcher(library: context.library, manifest: context.manifest, selection: selection,
                          defaultPresetID: app.syncSettings.presetID)
    }

    // MARK: Selection

    /// Nil when no device is known.
    func status(of album: Album) -> AlbumStatus? {
        guard isAvailable else { return nil }
        return matcher?.status(of: album) ?? (selection.selects(album) ? .pending : AlbumStatus.none)
    }

    func isSelected(_ album: Album) -> Bool { selection.selects(album) }
    /// Selected through its artist: only the artist toggle removes it.
    func isSelectedByArtist(_ album: Album) -> Bool { !selection.excludedAlbums.contains(album.id) && album.artistId.map(selection.artists.contains) == true }
    func isArtistSelected(_ id: String) -> Bool { selection.artists.contains(id) }
    func isPlaylistSelected(_ id: String) -> Bool { selection.playlists.contains(id) }

    /// Adds or removes an album; adding an album iTunes already put on the iPod asks first.
    func toggle(_ album: Album, confirmed: Bool = false) {
        let on = !isSelected(album)
        if on, !confirmed, status(of: album) == .foreign { foreignAlbum = album; return }
        update { if on { $0.albums.insert(album.id); $0.excludedAlbums.remove(album.id) } else { $0.albums.remove(album.id) } }
    }

    func toggleArtist(_ id: String) {
        update { if $0.artists.remove(id) == nil { $0.artists.insert(id) } }
    }

    func togglePlaylist(_ id: String) {
        update { if $0.playlists.remove(id) == nil { $0.playlists.insert(id) } }
    }

    private func update(_ change: (inout Selection) -> Void) {
        guard let key = deviceKey, !isRunning else { return }
        change(&selection)
        updateMatcher()
        schedulePlan()
        saveTask?.cancel()
        let selection = selection, store = SelectionStore(locations: locations)
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do { try store.save(selection, deviceKey: key) } catch { app?.report(error) }
        }
    }

    // MARK: Plan

    /// Expands the selection and plans in the background, 0.5 s after the last change.
    func schedulePlan() {
        planTask?.cancel()
        preview = nil
        guard let app, let client = app.client, let device = app.ipod.current, let context, !isRunning else {
            isPlanning = false
            app?.ipod.projectedSyncDelta = nil
            return
        }
        previewError = nil
        isPlanning = true
        checked = nil
        planID += 1
        let selection = selection, settings = app.syncSettings
        let needsGuid = app.ipod.snapshot?.guid == nil
        // The mirror answers in milliseconds; the server is asked only for albums it lacks.
        let expander = expander ?? SelectionExpander(client: client, local: app.usesLocalLibrary ? app.library?.database.local : nil)
        self.expander = expander
        planTask = Task { [planID] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                let expansion = try await expander.expand(selection, defaultPresetID: settings.presetID, soundCheck: settings.soundCheck,
                                                              fullAlbums: settings.fullAlbums) { done, total in
                    Task { @MainActor in
                        guard self.planID == planID, self.isPlanning, done > self.checked?.done ?? 0 else { return }
                        self.checked = (done, total)
                    }
                }
                let songs = expansion.songs, playlists = expansion.playlists
                // The iPod disk can be slow or busy: read it off the main thread.
                let (plan, hasPlayCounts) = await Task.detached(priority: .userInitiated) {
                    let input = PlannerInput(desired: songs, playlists: playlists, manifest: context.manifest,
                                             library: context.library, freeBytes: (try? device.capacity().available) ?? 0)
                    return (SyncPlanner.plan(input), FileManager.default.fileExists(atPath: device.playCountsURL.path))
                }.value
                try Task.checkCancellation()
                var warnings = [context.warning].compactMap { $0 }
                if !expansion.missing.isEmpty {
                    warnings.append("\(expansion.missing.count) selected items no longer exist on the server and are skipped.")
                }
                preview = Preview(plan: plan, warnings: warnings, needsGuid: needsGuid && plan.touchesStock,
                                  hasPlayCounts: hasPlayCounts)
                app.ipod.projectedSyncDelta = plan.isEmpty ? nil : plan.addBytes - plan.freedBytes
                isPlanning = false
            } catch where !error.isCancellation && !Task.isCancelled {
                // Never plan without a full expansion: missing songs would be deleted.
                previewError = error.localizedDescription
                isPlanning = false
            } catch {}
        }
    }

    // MARK: Run

    func start() {
        guard let preview, preview.canRun else { return }
        execute(preview.plan)
    }

    /// Deletes `tracksToDelete` from the iPod now. Their albums leave the selection, so the next sync does not add them again.
    func deleteConfirmed() {
        let dbids = Set(tracksToDelete.map(\.dbid))
        tracksToDelete = []
        guard !dbids.isEmpty else { return }
        let albums = Set(context?.manifest.entries.values.filter { dbids.contains($0.dbid) }.map(\.albumID) ?? [])
        update { $0.albums.subtract(albums); $0.excludedAlbums.formUnion(albums) }
        var plan = SyncPlan()
        plan.deleteTracks = dbids
        plan.reserveBytes = 0
        showSheet = true
        execute(plan)
    }

    private func execute(_ plan: SyncPlan) {
        guard let app, let client = app.client, let device = app.ipod.current, !isRunning else { return }
        run = Run()
        planTask?.cancel()
        itemIndex = [:]
        app.ipod.isSyncing = true
        let settings = app.syncSettings
        Task {
            do {
                for try await event in await engine.run(plan: plan, device: device, client: client, settings: settings) {
                    apply(event)
                }
            } catch where !(error is CancellationError) {
                run?.error = error.localizedDescription
            } catch {}
            if run?.isFinished == false { run?.error = "The sync stopped unexpectedly." }
            app.ipod.isSyncing = false
            app.ipod.reload()
        }
    }

    /// Stops after the files in work; the database is still written so the iPod stays consistent.
    func cancel() {
        run?.cancelling = true
        Task { await engine.cancel() }
    }

    /// Clears a finished run (sheet closed).
    func dismissRun() {
        if run?.isFinished == true { run = nil }
    }

    private func apply(_ event: SyncEvent) {
        switch event {
        case .phase(let phase): run?.phase = phase
        case .progress(let progress): run?.progress = progress
        case .warning(let text): run?.warnings.append(text)
        case .finished(let summary): run?.summary = summary
        case .item(let id, let title, let stage):
            if let i = itemIndex[id] {
                run?.items[i].stage = stage
            } else {
                itemIndex[id] = run?.items.count
                run?.items.append(Item(id: id, title: title, stage: stage))
            }
        }
    }

    // MARK: Other

    func cleanOrphans() {
        guard let app, let device = app.ipod.current else { return }
        Task {
            do {
                try await engine.cleanOrphans(device: device)
                app.ipod.reload()
            } catch { app.report(error) }
        }
    }

    /// Sends scrobbles left from earlier syncs; failures stay queued for the next time.
    func flushScrobbles(_ client: SubsonicClient) {
        Task { await scrobbler.flush(client: client) }
    }
}
