import Artwork
import Device
import Foundation
import ITunesDB
import Subsonic
import Support
import Transcode

/// One sync run. State lives here; the steps are in the `SyncJob+*` files.
actor SyncJob {
    let plan: SyncPlan
    let device: IPodDevice
    let client: SubsonicClient
    let settings: SyncSettings
    let locations: SyncLocations
    let scrobbler: Scrobbler
    let emit: @Sendable (SyncEvent) -> Void

    var key = ""
    var guid: [UInt8]?
    var ffmpeg: FFmpeg?
    /// False for a Rockbox-only plan: the iTunesDB is not touched at all.
    var usesDB = false
    var db = ITunesDB.empty(name: "iPod")
    var artworkDB: ArtworkDB?
    var manifest = Manifest()
    /// The manifest as last written to the device.
    var committed = Manifest()
    var workDir: URL!

    var dbDirty = false
    var artworkDirty = false
    var manifestDirty = false
    var statsFilesPending = false
    /// Paths (relative to the volume) to delete once the database that no longer lists them is written.
    var pendingDeletes: [String] = []
    var sinceCheckpoint = 0
    var lastCheckpoint = Date()
    /// A failed database write during transfers: stops the workers.
    var transferError: (any Error)?
    var summary = SyncSummary()
    var progress = SyncProgress()

    init(plan: SyncPlan, device: IPodDevice, client: SubsonicClient, settings: SyncSettings, locations: SyncLocations,
         scrobbler: Scrobbler, emit: @escaping @Sendable (SyncEvent) -> Void) {
        self.plan = plan
        self.device = device
        self.client = client
        self.settings = settings
        self.locations = locations
        self.scrobbler = scrobbler
        self.emit = emit
    }

    func run() async throws -> SyncSummary {
        emit(.phase(.preparing))
        try await preflight()
        workDir = locations.workDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        emit(.phase(.backingUp))
        try Backups.create(device: device, root: locations.backupsDirectory(key: key))
        if usesDB { Backups.keepOriginal(device: device) }

        emit(.phase(.readingDevice))
        try await readDevice()

        emit(.phase(.removing))
        removeAndRetag()
        try checkpoint()

        try await transfer()
        if Task.isCancelled {
            summary.cancelled = true
        } else {
            emit(.phase(.artwork))
            await artworkPass()
            await rockboxCovers()
            emit(.phase(.playlists))
            reconcilePlaylists()
        }
        emit(.phase(.writing))
        try checkpoint(final: true)

        if !summary.cancelled {
            emit(.phase(.scrobbling))
            let result = await scrobbler.flush(client: client)
            summary.scrobblesSent = result.sent
        }
        summary.scrobblesPending = await scrobbler.pendingCount
        if settings.ejectAfterSync, !summary.cancelled {
            emit(.phase(.ejecting))
            do { try await device.eject() } catch { emit(.warning("Eject failed: \(error.localizedDescription)")) }
        }
        return summary
    }

    // MARK: Preflight

    private func preflight() async throws {
        key = DeviceKey.resolve(for: device, settings: settings)
        // Play statistics are merged on every run that can write the database.
        usesDB = plan.touchesStock || Self.hasPlayStatistics(device)
        if usesDB {
            guid = FirewireGuid.resolve(for: device, manualOverride: settings.manualGuids[device.volumeUUID ?? ""])
            if guid == nil {
                guard !plan.touchesStock else { throw SyncError.noFirewireGuid }
                usesDB = false
                warn("Play counts were not read: the FireWire GUID is unknown.")
            }
        }
        guard plan.fits else { throw SyncError.notEnoughSpace }
        if plan.transferCount > 0 {
            guard let tools = FFmpeg.locate(explicitPath: settings.ffmpegPath) else { throw SyncError.ffmpegMissing }
            ffmpeg = tools
            let presets = Set((plan.add + plan.reencode.map(\.desired)).map(\.preset))
            for preset in presets {
                if try await !tools.supports(preset) { throw SyncError.encoderMissing(preset.codec.ffmpegEncoder) }
            }
        }
        try? FileManager.default.createDirectory(at: device.musicSyncDir, withIntermediateDirectories: true)
        // Leftovers of crashed runs.
        try? FileManager.default.removeItem(at: locations.workDirectory)
    }

    static func hasPlayStatistics(_ device: IPodDevice) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: device.iTunesDir.path)) ?? [])
            .contains { statsFiles.contains($0) || $0.hasPrefix("OTGPlaylistInfo") }
    }

    // MARK: Events

    func warn(_ message: String) { emit(.warning(message)) }

    func publishProgress() { emit(.progress(progress)) }
}

extension Preset.Codec {
    var ffmpegEncoder: String {
        switch self {
        case .aac: "aac_at"
        case .flac: "flac"
        case .opus: "libopus"
        case .alac: "alac"
        }
    }
}
