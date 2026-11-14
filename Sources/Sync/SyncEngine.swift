import Device
import Foundation
import ITunesDB
import Subsonic

public struct Orphan: Sendable, Equatable {
    public var path: String
    public var size: Int64
}

/// Runs syncs and maintenance for iPods. One run at a time.
public actor SyncEngine {
    private let locations: SyncLocations
    private let scrobbler: Scrobbler
    private var current: Task<Void, Never>?

    /// The app's engine shares `Scrobbler.shared`, so there is one writer of the queue file.
    public init(locations: SyncLocations = .standard, scrobbler: Scrobbler? = nil) {
        self.locations = locations
        self.scrobbler = scrobbler
            ?? (locations.scrobbleQueue == SyncLocations.standard.scrobbleQueue ? .shared : Scrobbler(queueURL: locations.scrobbleQueue))
    }

    /// Starts a sync. Events end with `.finished`; a cancelled run (see `cancel()` or cancelling the consumer)
    /// writes what it finished, emits `.finished` with `cancelled == true` and then throws `CancellationError`.
    /// Errors before any change (no GUID, no ffmpeg, no space) are thrown through the stream.
    public func run(plan: SyncPlan, device: IPodDevice, client: SubsonicClient,
                    settings: SyncSettings) -> AsyncThrowingStream<SyncEvent, Error> {
        AsyncThrowingStream { continuation in
            guard current == nil else { return continuation.finish(throwing: SyncError.alreadyRunning) }
            let job = SyncJob(plan: plan, device: device, client: client, settings: settings, locations: locations,
                              scrobbler: scrobbler, emit: { continuation.yield($0) })
            let task = Task {
                do {
                    let summary = try await job.run()
                    continuation.yield(.finished(summary))
                    continuation.finish(throwing: summary.cancelled ? CancellationError() : nil)
                } catch {
                    continuation.finish(throwing: error)
                }
                self.finished()
            }
            current = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks the running sync to stop after the current files; the stream still ends with a summary.
    public func cancel() { current?.cancel() }

    private func finished() { current = nil }

    // MARK: Orphans

    /// Files under `iPod_Control/Music` that the iTunesDB does not list.
    public func orphans(device: IPodDevice) throws -> [Orphan] {
        guard FileManager.default.fileExists(atPath: device.iTunesDBURL.path) else {
            throw SyncError.databaseUnreadable("iTunesDB is missing")
        }
        let db: ITunesDB
        do { db = try ITunesDB.parse(Data(contentsOf: device.iTunesDBURL)) } catch { throw SyncError.databaseUnreadable("\(error)") }
        return try device.layout.orphans(referenced: Set(db.tracks.map { ITunesDB.relativePath(ipodLocation: $0.location) }))
            .map { Orphan(path: $0.path, size: $0.size) }
    }

    /// Deletes orphans. Refuses while a sync runs or when the database cannot be read.
    @discardableResult
    public func cleanOrphans(device: IPodDevice) throws -> [Orphan] {
        guard current == nil else { throw SyncError.alreadyRunning }
        let found = try orphans(device: device)
        for orphan in found { try? FileManager.default.removeItem(at: device.mountURL.appendingPathComponent(orphan.path)) }
        return found
    }
}
