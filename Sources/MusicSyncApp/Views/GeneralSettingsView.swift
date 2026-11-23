import Support
import SwiftUI

struct GeneralSettingsView: View {
    #if os(macOS)
    @AppStorage(MenuBarPlayer.shownKey, store: .app) private var showsItem = true
    @AppStorage(MenuBarPlayer.titleKey, store: .app) private var showsTitle = false
    #endif

    var body: some View {
        Form {
            #if os(macOS)
            Section("Menu Bar") {
                Toggle("Show player in the menu bar", isOn: $showsItem)
                Toggle("Show song title next to the icon", isOn: $showsTitle).disabled(!showsItem)
            }
            #endif
            SystemSettingsSections()
        }
        .formStyle(.grouped)
        .settingsPageSize(width: 480)
    }
}
