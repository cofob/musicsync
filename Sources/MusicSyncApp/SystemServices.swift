import AppKit
import Integration
import Library
import Observation
import Subsonic
import Support

/// macOS integration: sharing, deep links, Spotlight, global shortcuts and track notifications.
/// It follows the app model through Observation, so the model itself needs no hooks.
@MainActor @Observable
final class SystemServices {
    private static let hotKeysKey = "hotKeys", spotlightKey = "spotlightIndexing", notifyKey = "trackNotifications"

    @ObservationIgnored unowned let app: AppModel
    /// True when the server makes public share links (OpenSubsonic `createShare`; Navidrome `EnableSharing`).
    var sharesSupported = false
    /// Public links made this session, by item id; sharing an item twice reuses its link.
    @ObservationIgnored var shareLinks: [String: URL] = [:]

    var hotKeys: HotKeySettings {
        didSet {
            UserDefaults.app.set(try? JSONEncoder().encode(hotKeys), forKey: Self.hotKeysKey)
            applyHotKeys()
        }
    }
    /// Actions whose combo another app holds.
    var takenHotKeys: Set<HotKeyAction> = []
    @ObservationIgnored var hotKeyCenter: HotKeyCenter?

    var indexesSpotlight: Bool {
        didSet { UserDefaults.app.set(indexesSpotlight, forKey: Self.spotlightKey); updateSpotlight() }
    }
    /// Nil in demo mode: the demo library must not reach the system index.
    @ObservationIgnored let spotlight: SpotlightIndexer?
    @ObservationIgnored var spotlightTask: Task<Void, Never>?

    var notifiesTrackChange: Bool {
        didSet { UserDefaults.app.set(notifiesTrackChange, forKey: Self.notifyKey); if notifiesTrackChange { requestNotifications() } }
    }

    /// Set by the main window; opens a new one after it was closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var watchers: [AnyObject] = []

    init(app: AppModel) {
        self.app = app
        hotKeys = UserDefaults.app.data(forKey: Self.hotKeysKey).flatMap { try? JSONDecoder().decode(HotKeySettings.self, from: $0) }
            ?? HotKeySettings()
        indexesSpotlight = UserDefaults.app.object(forKey: Self.spotlightKey) as? Bool ?? true
        notifiesTrackChange = UserDefaults.app.bool(forKey: Self.notifyKey)
        spotlight = app.demo ? nil : SpotlightIndexer(sink: SystemSpotlight(), stateURL: Paths.appSupport.appendingPathComponent("spotlight.json"))
    }

    /// Starts following the model; called once at launch.
    func start() {
        watchers = [
            Watcher({ [app] in app.store.map(ObjectIdentifier.init) }) { [weak self] _ in self?.serverChanged() },
            Watcher({ [app] in app.usesLocalLibrary ? app.libraryVersion : -1 }) { [weak self] _ in self?.updateSpotlight() },
            Watcher({ [app] in app.player.current?.id }) { [weak self] _ in self?.trackChanged() },
        ]
        applyHotKeys()
        IntentHost.system = self
    }

    private func serverChanged() {
        sharesSupported = false
        shareLinks = [:]
        checkShares()
        let key = app.client.map { LibraryDatabase.serverKey(for: $0.config) }
        if let spotlight { enqueueSpotlight { try? await spotlight.use(serverKey: key) } }
    }
}

/// Calls `action` with the current value, then again each time Observation sees it change.
@MainActor final class Watcher<T: Equatable> {
    private let value: () -> T
    private let action: (T) -> Void
    private var last: T?

    init(_ value: @escaping () -> T, _ action: @escaping (T) -> Void) {
        self.value = value
        self.action = action
        track()
    }

    private func track() {
        let current = withObservationTracking(value) { [weak self] in Task { @MainActor in self?.track() } }
        guard current != last else { return }
        last = current
        action(current)
    }
}
