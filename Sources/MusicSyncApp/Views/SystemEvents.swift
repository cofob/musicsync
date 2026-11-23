import CoreSpotlight
import Integration
import SwiftUI

enum MainWindow {
    /// The `WindowGroup` id; SwiftUI starts its window identifiers with it.
    static let id = "main"
}

/// The main window takes `musicsync://` links, Spotlight results and Handoff activities, and offers its page
/// (or the playing song) as the current activity.
struct SystemEvents: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        let system = model.system
        let current = system.activityLink
        content
            .onOpenURL { url in DeepLink(url: url).map(system.open) }
            .onContinueUserActivity(DeepLink.activityType) { SystemServices.link(in: $0).map(system.open) }
            .onContinueUserActivity(CSSearchableItemActionType) { SystemServices.link(in: $0).map(system.open) }
            // Demo runs stay out of Handoff and Spotlight suggestions.
            .userActivity(DeepLink.activityType, isActive: current != nil && !model.demo) { activity in
                guard let current else { return }
                activity.title = current.title
                activity.userInfo = ["url": current.link.url.absoluteString]
                activity.requiredUserInfoKeys = ["url"]
                activity.targetContentIdentifier = current.link.url.absoluteString
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = true
            }
            // Links go to this window instead of opening a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onAppear { system.openMainWindow = { openWindow(id: MainWindow.id) } }
    }
}
