import Foundation
import Subsonic

/// Background copy of the server library into the local database. Never throws into the app:
/// failures show up in `status` and the next scheduled pass tries again.
public actor LibraryMirror {
    private nonisolated let hub = StatusHub(MirrorStatus())
    private let database: LibraryDatabase
    private var settings: MirrorSettings
    private var client: SubsonicClient?
    private var loop: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var wakePending = false
    private var paused = false
    private var retrySoon = false

    public init(database: LibraryDatabase, settings: MirrorSettings = MirrorSettings()) {
        self.database = database
        self.settings = settings
        hub.update { $0.state = settings.enabled ? .idle : .disabled }
    }

    /// Progress snapshots: the current one first, then every change.
    public nonisolated var status: AsyncStream<MirrorStatus> { hub.stream() }
    public nonisolated var currentStatus: MirrorStatus { hub.latest }

    // MARK: Control

    /// Starts the schedule: one pass now, then one every `intervalMinutes`. Replaces an earlier client.
    public func start(client: SubsonicClient) {
        self.client = client
        passTask?.cancel()
        if loop == nil { loop = Task { await self.runLoop() } } else { wake() }
    }

    /// Manual pass that ignores the scan gate. Works while disabled or paused. Returns when it is done.
    public func syncNow() async { await runPass(force: true) }

    /// Stops the running pass; progress is kept and resumes later.
    public func pause() {
        paused = true
        passTask?.cancel()
        hub.update { $0.state = .paused }
    }

    public func resume() {
        paused = false
        refreshState()
        wake()
    }

    /// Cancels everything and waits for the running pass to end. `start` can be called again.
    public func stop() async {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        let running = passTask
        running?.cancel()
        await running?.value
        client = nil
        refreshState()
    }

    public func update(settings: MirrorSettings) {
        self.settings = settings
        if !settings.enabled { passTask?.cancel() }
        refreshState()
        wake()
    }

    // MARK: Loop

    private func runLoop() async {
        while !Task.isCancelled {
            if settings.enabled, !paused, client != nil { await runPass(force: false) }
            await idle()
        }
    }

    private func runPass(force: Bool) async {
        while let running = passTask { await running.value }
        guard let client else { return }
        let pass = MirrorPass(client: client, database: database, settings: settings, hub: hub, force: force)
        let task = Task { let outcome = await pass.run(); self.passFinished(outcome) }
        passTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func passFinished(_ outcome: MirrorPass.Outcome) {
        passTask = nil
        retrySoon = false
        switch outcome {
        case .success: hub.update { $0.lastSuccess = Date() }
        case .failed(let message): retrySoon = true; hub.update { $0.state = .failed(message) }
        case .cancelled: break
        }
        hub.update { $0.phase = nil; $0.done = 0; $0.total = nil }
        if case .failed = hub.latest.state { return }
        refreshState()
    }

    private func refreshState() {
        guard passTask == nil else { return }
        hub.update { $0.state = paused ? .paused : (settings.enabled ? .idle : .disabled) }
    }

    private func wake() {
        wakePending = true
        sleeper?.cancel()
    }

    private func idle() async {
        if wakePending { wakePending = false; return }
        // After a failure try again sooner than the normal interval.
        let minutes = retrySoon ? min(5, settings.intervalMinutes) : settings.intervalMinutes
        let sleep = Task { _ = try? await Task.sleep(for: .seconds(max(1, minutes) * 60)) }
        sleeper = sleep
        await withTaskCancellationHandler { await sleep.value } onCancel: { sleep.cancel() }
        sleeper = nil
        wakePending = false
    }
}
