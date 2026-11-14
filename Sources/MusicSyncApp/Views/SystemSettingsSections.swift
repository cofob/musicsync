import SwiftUI

/// Notifications and Spotlight, in Settings > General.
struct SystemSettingsSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var system = model.system
        Section("Notifications") {
            Toggle("Show a notification when the song changes", isOn: $system.notifiesTrackChange)
            Text("Only while MusicSync is in the background.").font(.footnote).foregroundStyle(.secondary)
        }
        Section("Spotlight") {
            Toggle("Show albums, artists and playlists in Spotlight", isOn: $system.indexesSpotlight)
            Text("Uses the local library. Turning this off removes them from Spotlight.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
