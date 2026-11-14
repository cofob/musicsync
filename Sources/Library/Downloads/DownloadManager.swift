import Foundation
import Subsonic
import Support

/// Downloads songs for offline use, a few at a time, in the background. The queue lives in `store`,
/// so it resumes after a restart. Files are moved into place only when complete.
public actor DownloadManager {
    public nonisolated let store: DownloadStore
    public nonisolated let filesDirectory: URL
    /// Covers of downloaded songs and pins, named like the cover cache (`<id>@600`).
    public nonisolated let coversDirectory: URL
    private nonisolated let hub = Hub(DownloadStatus())
    private var settings: DownloadSettings
    private var client: SubsonicClient?
    private var offline = false
    /// Songs only rules keep start only while this is set (network, power and streaming allow it).
    private var smartAllowed = false
    private(set) var running: [String: Task<Void, Never>] = [:]
    /// Songs waiting for a retry after a failure, and their failure counts.
    private(set) var waiting: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var pumping = false
    private var pumpAgain = false
    private let backoff: @Sendable (Int) -> Duration

    static let maxAttempts = 3
    public static let coverSize = 600
    /// Kept free on the disk.
    static let reserveBytes = SmartPlanner.reserveBytes

    /// `serverKey` identifies server and user (see `LibraryDatabase.serverKey`); each key gets its own folder.
    public init(serverKey: String, directory: URL? = nil, settings: DownloadSettings = DownloadSettings(),
                backoff: @escaping @Sendable (Int) -> Duration = { .seconds(1 << $0) }) {
        let base = directory ?? Paths.appSupport("downloads", LibraryDatabase.hash(serverKey))
        filesDirectory = base.appendingPathComponent("files")
        coversDirectory = base.appendingPathComponent("covers")
        for dir in [filesDirectory, coversDirectory] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        store = DownloadStore(fileURL: base.appendingPathComponent("downloads.sqlite"))
        self.settings = settings
        self.backoff = backoff
    }

    /// The current status first, then every change.
    public nonisolated var status: AsyncStream<DownloadStatus> { hub.stream() }
    public nonisolated var currentStatus: DownloadStatus { hub.latest }

    public nonisolated func fileURL(_ entry: DownloadEntry) -> URL? {
        entry.state == .done ? entry.fileName.map(filesDirectory.appendingPathComponent) : nil
    }

    // MARK: Control

    /// Starts (or resumes) the queue with `client`.
    public func start(client: SubsonicClient) async {
        self.client = client
        try? await store.resetInterrupted()
        await sweepParts()
        changed()
        await pump()
    }

    /// Cancels the running downloads; they start again with the next `start`.
    public func stop() async {
        client = nil
        let tasks = Array(running.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        try? await store.resetInterrupted()
        changed()
    }

    public func update(settings: DownloadSettings) async {
        self.settings = settings
        await pump()
    }

    /// While offline nothing starts. Going online retries the songs that failed.
    public func setOffline(_ offline: Bool) async {
        guard offline != self.offline else { return }
        self.offline = offline
        if !offline {
            attempts = [:]
            try? await store.requeue()
            changed()
        }
        await pump()
    }

    public func setSmartAllowed(_ allowed: Bool) async {
        guard allowed != smartAllowed else { return }
        smartAllowed = allowed
        changed()
        await pump()
    }

    // MARK: Pins

    /// Downloads `songs` on their own.
    public func download(_ songs: [Song]) async throws {
        try await store.add(songs, reason: .song)
        try await store.requeue(songs.map(\.id))
        changed()
        await pump()
    }

    /// Keeps the album or playlist offline with exactly `songs`; also used to follow content changes.
    public func pin(_ pin: DownloadPin, songs: [Song]) async throws {
        let released = try await store.pin(pin, songs: songs)
        try await store.requeue(songs.map(\.id))
        await release(released)
        if let cover = pin.coverArt { Task { await self.ensureCover(cover) } }
        await pump()
    }

    /// Reads every pin's songs again (`resolve` returns nil when they are unknown) and follows the changes.
    public func refreshPins(_ resolve: @Sendable (DownloadPin) async -> [Song]?) async {
        for pin in await store.pins() {
            guard let songs = await resolve(pin) else { continue }
            let released = (try? await store.pin(pin, songs: songs)) ?? []
            await release(released)
        }
        changed()
        await pump()
    }

    /// Drops `reason` from `songIDs` (all songs when nil); songs without reasons are deleted.
    public func remove(_ reason: DownloadReason, songIDs: [String]? = nil) async throws {
        await release(try await store.remove(reason, songIDs: songIDs))
    }

    /// Evaluates the smart rules against `library` and follows the plan; nil (nothing changes) while the mirror
    /// is not complete. Songs the user keeps are never removed.
    @discardableResult
    public func updateSmart(from library: Library, day: String, now: Date = Date()) async throws -> SmartPlan? {
        let settings = settings
        guard let candidates = await library.smartCandidates(settings.smart, day: day, now: now) else { return nil }
        let lastPlayed = await library.history.stats().compactMapValues(\.lastPlayed)
        let plan = SmartPlanner.plan(candidates, settings: settings.smart, entries: await store.entries(), lastPlayed: lastPlayed,
                                     freeDisk: freeDisk()) { settings.plan(for: $0).estimate($0) }
        try Task.checkCancellation()
        await release(try await store.setSmart(plan.songs))
        await pump()
        return plan
    }

    public func removeAll() async throws {
        await release(try await store.removeAll())
    }

    /// Stops a song's download; it stays failed ("Cancelled") until `retry`.
    public func cancel(_ id: String) async {
        // The task first: its `run` then writes nothing more.
        running[id]?.cancel()
        waiting.remove(id)
        try? await store.markFailed(id, error: DownloadEntry.cancelledMessage)
        if let entry = await store.entry(id) { removePart(entry.song) }
        changed()
    }

    /// Queues failed songs again: `ids`, or all failures but cancels.
    public func retry(_ ids: [String]? = nil) async {
        for id in ids ?? Array(attempts.keys) { attempts[id] = nil }
        try? await store.requeue(ids)
        changed()
        await pump()
    }

    private func release(_ songs: [DownloadStore.Released]) async {
        guard !songs.isEmpty else { return changed() }
        for song in songs {
            running[song.id]?.cancel()
            waiting.remove(song.id)
            if let name = song.fileName { try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(name)) }
        }
        await sweepParts()
        await pruneCovers()
        changed()
        await pump()
    }

    /// Deletes covers no song or pin uses any more.
    private func pruneCovers() async {
        let entries = await store.entries(), pins = await store.pins()
        let used = Set((entries.compactMap(\.song.coverArt) + pins.compactMap(\.coverArt)).map(Self.coverFileName))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: coversDirectory.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Queue

    /// Starts queued songs until `concurrency` run. Runs one at a time; a call during a run repeats it.
    private func pump() async {
        guard !pumping else { pumpAgain = true; return }
        pumping = true
        repeat {
            pumpAgain = false
            await fill()
        } while pumpAgain
        pumping = false
    }

    private func fill() async {
        guard let client else { return }
        if offline { return hub.update { $0.blocked = .offline } }
        while running.count < max(1, settings.concurrency),
              let entry = await store.nextQueued(excluding: Set(running.keys).union(waiting), smart: smartAllowed) {
            if let block = await block(for: entry) { return hub.update { $0.blocked = block } }
            let plan = settings.plan(for: entry.song)
            running[entry.id] = Task { await self.run(entry, plan: plan, client: client) }
        }
        hub.update { $0.blocked = nil }
    }

    /// Storage limit (user downloads only; smart ones have their own budgets) and free disk space, counting the running downloads.
    private func block(for entry: DownloadEntry) async -> DownloadStatus.Block? {
        let need = settings.plan(for: entry.song).estimate(entry.song)
        var inFlight: Int64 = 0
        for id in running.keys { if let e = await store.entry(id) { inFlight += settings.plan(for: e.song).estimate(e.song) } }
        if entry.isUserKept, let limit = settings.limitBytes, await store.userBytes() + inFlight + need > limit { return .storageLimit }
        if let free = freeDisk(), free < inFlight + need + Self.reserveBytes { return .diskFull }
        return nil
    }

    private func freeDisk() -> Int64? {
        (try? filesDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private func run(_ entry: DownloadEntry, plan: DownloadPlan, client: SubsonicClient) async {
        let id = entry.id
        guard (try? await store.markDownloading(id)) == true, !Task.isCancelled else { return await finished(id) }
        changed()
        let hub = hub, estimate = plan.estimate(entry.song)
        let name = Self.fileName(id, suffix: plan.suffix), part = partURL(entry.song, plan: plan)
        // Only originals resume: a conversion may differ from one request to the next.
        if plan.format != nil { try? FileManager.default.removeItem(at: part) }
        do {
            try await client.download(id: id, format: plan.format, maxBitRate: plan.maxBitRate, resuming: part) { got, expected in
                let total = expected > 0 ? expected : estimate
                hub.update { $0.progress[id] = min(0.99, Double(got) / Double(max(1, total))) }
            }
            try Task.checkCancellation()
            do { try await DownloadCheck.verify(part, song: entry.song, original: plan.format == nil) } catch {
                // The server sent all it had: a new try starts over.
                try? FileManager.default.removeItem(at: part)
                throw error
            }
            let size = try place(part, as: name)
            await extras(entry.song, client: client)
            if !Task.isCancelled, try await store.markDone(id, fileName: name, size: size, format: plan.suffix, bitRate: plan.bitRate) {
                hub.update { $0.batchDone += 1 }
            } else {
                try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(name))
            }
        } catch where !Task.isCancelled {
            await failed(id, error)
        } catch {
            // Kept for a resume when the queue only stopped; gone when the user cancelled or removed the song.
            if await store.entry(id)?.state != .downloading { try? FileManager.default.removeItem(at: part) }
        }
        await finished(id)
    }

    private func finished(_ id: String) async {
        running[id] = nil
        hub.update { $0.progress[id] = nil }
        changed()
        await pump()
    }

    /// Retries with backoff; after `maxAttempts` the song stays failed.
    private func failed(_ id: String, _ error: Error) async {
        let count = (attempts[id] ?? 0) + 1
        attempts[id] = count
        libraryLog.warning("download \(id) failed (\(count)): \(error.localizedDescription)")
        let retry = count < Self.maxAttempts
        try? await store.markFailure(id, error: error.friendlyMessage, retry: retry)
        guard retry else { return }
        waiting.insert(id)
        let delay = backoff(count)
        Task {
            try? await Task.sleep(for: delay)
            await self.endWait(id)
        }
    }

    private func endWait(_ id: String) async {
        guard waiting.remove(id) != nil else { return }
        await pump()
    }

    /// Renames the checked part file to its final name, so a half-written file never has it.
    private func place(_ part: URL, as name: String) throws -> Int64 {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: part) }
        let dest = filesDirectory.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: part) } else { try fm.moveItem(at: part, to: dest) }
        return Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// The unfinished download of `song`, kept between tries. It has the song's suffix, so AVFoundation can read it.
    private func partURL(_ song: Song, plan: DownloadPlan) -> URL {
        filesDirectory.appendingPathComponent(Self.partPrefix + Self.fileName(song.id, suffix: plan.suffix))
    }

    private func removePart(_ song: Song) {
        try? FileManager.default.removeItem(at: partURL(song, plan: settings.plan(for: song)))
    }

    /// Deletes part files of songs that are no longer in the store (removed, or left from a crash).
    private func sweepParts() async {
        let kept = Set(await store.entries().map { LibraryDatabase.hash($0.id) })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: filesDirectory.path)) ?? [] where name.hasPrefix(Self.partPrefix) {
            let hash = name.dropFirst(Self.partPrefix.count).prefix { $0 != "." }
            if !kept.contains(String(hash)) { try? FileManager.default.removeItem(at: filesDirectory.appendingPathComponent(name)) }
        }
    }

    /// Cover and lyrics, so the song shows fully offline. Failures are ignored.
    private func extras(_ song: Song, client: SubsonicClient) async {
        if let cover = song.coverArt { await ensureCover(cover) }
        if await store.lyrics(song.id) == nil, let lyrics = try? await client.getLyricsBySongId(id: song.id) {
            try? await store.setLyrics(song.id, lyrics)
        }
    }

    private func ensureCover(_ id: String) async {
        let file = coversDirectory.appendingPathComponent(Self.coverFileName(id))
        guard let client, !FileManager.default.fileExists(atPath: file.path),
              let data = try? await client.coverArt(id: id, size: Self.coverSize), !data.isEmpty else { return }
        try? FileManager.default.atomicWrite(data, to: file)
    }

    // MARK: Helpers

    /// Store changed: readers reload; an empty queue ends the batch.
    private func changed() {
        Task {
            let pending = await store.pendingCount(smart: smartAllowed)
            hub.update { status in
                status.revision += 1
                if pending == 0 { status.batchTotal = 0; status.batchDone = 0 } else { status.batchTotal = max(status.batchTotal, status.batchDone + pending) }
            }
        }
    }

    static let partPrefix = "part-"

    static func fileName(_ id: String, suffix: String) -> String {
        "\(LibraryDatabase.hash(id)).\(suffix.isEmpty ? "audio" : suffix)"
    }

    /// Same naming as the app's cover cache: `/` is not allowed in file names.
    public static func coverFileName(_ id: String) -> String { "\(id.replacingOccurrences(of: "/", with: "_"))@\(coverSize)" }
}
