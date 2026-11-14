import Support
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(MenuBarPlayer.shownKey, store: .app) private var showsItem = true
    @AppStorage(MenuBarPlayer.titleKey, store: .app) private var showsTitle = false

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show player in the menu bar", isOn: $showsItem)
                Toggle("Show song title next to the icon", isOn: $showsTitle).disabled(!showsItem)
            }
            SystemSettingsSections()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
