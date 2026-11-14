import Foundation
import Subsonic

/// One synchronization pass. Phases run in order and fail independently: a failing phase is recorded
/// and the next one still runs. Nothing is deleted locally except after a complete, successful listing.
struct MirrorPass: Sendable {
    enum Outcome: Sendable, Equatable { case success, failed(String), cancelled }

    let client: SubsonicClient
    let database: LibraryDatabase
    let settings: MirrorSettings
    let hub: StatusHub
    /// Ignore the scan gate and relist everything.
    let force: Bool

    static let gateAge: TimeInterval = 24 * 3600

    func run() async -> Outcome {
        hub.update { $0.state = .running; $0.warnings = 0; $0.lastWarning = nil }
        var failure: String?
        func attempt(_ phase: MirrorPhase, _ body: () async throws -> Void) async -> Bool {
            guard !Task.isCancelled else { return false }
            hub.update { $0.phase = phase; $0.done = 0; $0.total = nil }
            do { try await body(); return true } catch {
                if Task.isCancelled || error is CancellationError { return false }
                failure = failure ?? "\(phase.rawValue): \(error.friendlyMessage)"
                warn("\(phase.rawValue) failed: \(error.localizedDescription)")
                return false
            }
        }

        var scan: ScanStatus?
        _ = await attempt(.scan) { scan = try await client.getScanStatus() }
        let scanKey = scan?.lastScan
        if await !isGated(scanKey) {
            let artistsDone = await attempt(.artists, artists)
            var albumsDone = false
            _ = await attempt(.albums) { albumsDone = try await albums(scanKey: scanKey ?? "") }
            if artistsDone && albumsDone && scanKey != nil {
                try? await database.setMeta(["lastScan": scanKey, "lastFullSync": String(Date().timeIntervalSince1970)])
            } else if artistsDone && albumsDone {
                try? await database.setMeta(["lastScan": nil, "lastFullSync": String(Date().timeIntervalSince1970)])
            }
        }
        _ = await attempt(.tracks, tracks)
        _ = await attempt(.playlists, playlists)
        _ = await attempt(.favorites, favorites)
        if settings.includeCovers { _ = await attempt(.covers, covers) }
        if settings.includeLyrics { _ = await attempt(.lyrics, lyrics) }

        if Task.isCancelled { return .cancelled }
        return failure.map(Outcome.failed) ?? .success
    }

    /// Cheap pass: the server library did not change since the last full listing, which was recent.
    private func isGated(_ scanKey: String?) async -> Bool {
        guard !force, let scanKey,
              await database.meta("lastScan") == scanKey,
              let last = await database.meta("lastFullSync").flatMap(Double.init) else { return false }
        return Date().timeIntervalSince1970 - last < Self.gateAge
    }

    // MARK: Helpers

    func warn(_ message: String) {
        libraryLog.warning("\(message)")
        hub.update { $0.warnings += 1; $0.lastWarning = message }
    }

    func progress(total: Int? = nil, done: Int = 0) {
        hub.update { $0.done = done; $0.total = total }
    }

    func tick() { hub.update { $0.done += 1 } }

    func throttle() async throws {
        if settings.throttleMs > 0 { try await Task.sleep(for: .milliseconds(settings.throttleMs)) }
    }

    /// Runs `work` over `items` with bounded concurrency and per-item warnings; throws if the server keeps failing.
    func each(_ items: [String], limit: Int = 4, what: String, work: @escaping @Sendable (String) async throws -> Void) async throws {
        progress(total: items.count)
        let healthy = await forEachBounded(items, limit: limit, work: { id in
            try await throttle()
            try await work(id)
        }, onSuccess: tick, onFailure: { id, error in warn("\(what) \(id): \(error.localizedDescription)") })
        if !healthy { throw MirrorError.aborted("too many failures while fetching \(what)s") }
    }
}
