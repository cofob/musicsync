import Foundation
#if os(macOS)
import IOKit.ps
#else
import UIKit
#endif
import Library
import Network
import Observation

/// Smart downloads: the rules of Settings > Downloads keep songs offline on their own. They are evaluated after each
/// library sync, after new plays (at most every 30 minutes), on a settings change and on "Update Now". The work runs in
/// `DownloadManager`; this model reads the system conditions and shows the state.
@MainActor @Observable
final class SmartDownloads {
    private(set) var conditions = SmartConditions()
    private(set) var lastRun: Date?
    private(set) var lastPlan: SmartPlan?
    private(set) var isRunning = false
    /// Why the last evaluation did not finish.
    private(set) var problem: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var manager: DownloadManager?
    @ObservationIgnored private var settings: SmartSettings?
    /// Newest play seen by the last evaluation.
    @ObservationIgnored private var lastPlay: Date?
    /// Tells of power source changes on the main run loop.
    @ObservationIgnored private nonisolated(unsafe) var powerSource: CFRunLoopSource?

    init(app: AppModel) {
        self.app = app
        conditions.onPower = Self.onPower
        monitor.pathUpdateHandler = { [weak self] path in
            let network = Self.network(path)
            Task { @MainActor in if self?.conditions.network != network { self?.conditions.network = network } }
        }
        monitor.start(queue: DispatchQueue(label: "SmartDownloads.network"))
        watch()
        watchPower()
        poll()
    }

    deinit { if let powerSource { CFRunLoopSourceInvalidate(powerSource) } }

    var wait: SmartConditions.Wait? { conditions.wait(for: app.downloads.settings.smart) }

    /// Songs only rules keep that still wait or download.
    var pending: Int { app.downloads.entries.values.count { !$0.isUserKept && ($0.state == .queued || $0.state == .downloading) } }

    /// Evaluates the rules now (after `delay`); a newer call replaces a waiting one.
    func run(after delay: Duration = .zero) {
        runTask?.cancel()
        isRunning = false
        let downloads = app.downloads
        guard let manager = downloads.manager, let library = app.library,
              downloads.settings.smart.isOn || downloads.entries.values.contains(where: { !$0.smartRules.isEmpty }) else { return }
        let settings = downloads.settings
        runTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isRunning = true
            defer { if !Task.isCancelled { isRunning = false } }
            await manager.update(settings: settings)
            do {
                let plan = try await manager.updateSmart(from: library, day: MixModel.today)
                guard !Task.isCancelled, self.manager === manager else { return }
                if let plan { lastPlan = plan; lastRun = Date(); problem = nil } else { problem = "Waiting for the library sync to finish" }
            } catch where !error.isCancellation {
                problem = error.localizedDescription
            } catch {}
            lastPlay = await library.history.events(limit: 1).last?.startedAt
        }
    }

    // MARK: Conditions

    /// Applies what smart downloads follow, and again after every change of it.
    private func watch() {
        withObservationTracking { [weak self] in self?.apply() } onChange: { [weak self] in
            Task { @MainActor in self?.watch() }
        }
    }

    private func apply() {
        let downloads = app.downloads, player = app.player
        if downloads.manager !== manager {
            runTask?.cancel()
            manager = downloads.manager
            lastRun = nil; lastPlan = nil; problem = nil; isRunning = false; lastPlay = nil
        }
        var streaming = false
        if player.isPlaying, case .server(let song)? = player.current { streaming = downloads.fileURL(song.id) == nil }
        if conditions.streaming != streaming { conditions.streaming = streaming }
        let smart = downloads.settings.smart
        if smart != settings {
            settings = smart
            run(after: .seconds(2))
        }
        let allowed = conditions.wait(for: smart) == nil
        if let manager { Task { await manager.setSmartAllowed(allowed) } }
    }

    /// Reads the power source again when it changes.
    private func watchPower() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        _ = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let power = SmartDownloads.onPower
                if let self, self.conditions.onPower != power { self.conditions.onPower = power }
            }
        }
        #else
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let model = Unmanaged<SmartDownloads>.fromOpaque(context).takeUnretainedValue()
                let power = SmartDownloads.onPower
                if model.conditions.onPower != power { model.conditions.onPower = power }
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        #endif
    }

    /// Every 30 minutes: new plays change the most played songs and the mixes.
    private func poll() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard let self else { return }
                guard !isRunning, let library = app.library else { continue }
                if await library.history.events(limit: 1).last?.startedAt != lastPlay { run() }
            }
        }
    }

    private nonisolated static func network(_ path: NWPath) -> SmartConditions.Network {
        guard path.status == .satisfied else { return .none }
        let local = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        return local && !path.isExpensive && !path.isConstrained ? .unmetered : .metered
    }

    /// True on AC power, and on Macs without a battery.
    private static var onPower: Bool {
        #if os(iOS)
        return UIDevice.current.batteryState != .unplugged  // the simulator reports `.unknown`
        #else
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return type as String != kIOPSBatteryPowerValue
        #endif
    }
}
