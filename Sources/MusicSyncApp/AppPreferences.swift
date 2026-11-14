import Observation
import Preferences
import Support
import SwiftUI

/// Appearance, Home, listening and advanced settings; saved on every change. Shared, so that styles and plain views
/// (`Color.musicAccent`, `albumGridColumns`) read them too and draw again when they change.
@MainActor @Observable
final class AppPreferences {
    static let shared = AppPreferences()
    private static let lastPageKey = "lastPage"

    var appearance = AppearanceSettings.load() { didSet { if appearance != oldValue { appearance.save() } } }
    var home = HomeSettings.load() { didSet { if home != oldValue { home.save() } } }
    var listening = ListeningSettings.load() { didSet { if listening != oldValue { listening.save() } } }
    var advanced = AdvancedSettings.load() { didSet { if advanced != oldValue { advanced.save() } } }

    /// The page the main window opens with.
    var startPage: SidebarItem {
        SidebarItem(key: appearance.startPage.key(last: UserDefaults.app.string(forKey: Self.lastPageKey))) ?? .home
    }

    /// Notes the open page for the "Last Opened" start page.
    func remember(_ page: SidebarItem?) {
        if let key = page?.key { UserDefaults.app.set(key, forKey: Self.lastPageKey) }
    }

    /// Back to the defaults (Settings > Advanced > Reset All Settings).
    func reset() {
        appearance = AppearanceSettings()
        home = HomeSettings()
        listening = ListeningSettings()
        advanced = AdvancedSettings()
    }
}

extension Player {
    /// Plays go to the server unless a Private Session or Settings > Library turns that off.
    var sendsScrobbles: Bool { !privateSession && AppPreferences.shared.listening.scrobble }
}

extension AppearanceSettings.Accent {
    @MainActor var color: Color { (self == .album ? CoverAccent.shared.color : nil) ?? Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }

    var title: String { self == .album ? "Album Color" : rawValue.capitalized }
}
