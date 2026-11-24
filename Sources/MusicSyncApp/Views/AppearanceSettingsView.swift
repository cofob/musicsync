import Preferences
import SwiftUI

/// Settings > Appearance.
struct AppearanceSettingsView: View {
    var body: some View {
        @Bindable var prefs = AppPreferences.shared
        Form {
            Section {
                LabeledContent("Accent color") { AccentPicker(selection: $prefs.appearance.accent) }
            } footer: {
                SettingsFooter("Buttons, icons, the playing song and favorites use this color. Album Color takes it from the cover of the playing song.")
            }
            Section {
                Picker("Album covers", selection: $prefs.appearance.density) {
                    Text("Small").tag(AppearanceSettings.GridDensity.small)
                    Text("Medium").tag(AppearanceSettings.GridDensity.medium)
                    Text("Large").tag(AppearanceSettings.GridDensity.large)
                }
                .pickerStyle(.segmented)
            } footer: {
                SettingsFooter("Size of the covers on the Albums, Playlists, Favorites and Downloaded pages.")
            }
            Section {
                Picker("Now Playing background", selection: $prefs.appearance.nowPlayingBackground) {
                    Text("Animated Cover Colors").tag(AppearanceSettings.NowPlayingBackground.animated)
                    Text("Static Cover Colors").tag(AppearanceSettings.NowPlayingBackground.artwork)
                    Text("Plain").tag(AppearanceSettings.NowPlayingBackground.plain)
                    Text("Blurred Visualizer").tag(AppearanceSettings.NowPlayingBackground.visualizer)
                }
            } footer: {
                SettingsFooter("The full-window player takes its colors from the cover, stays dark gray, or shows the visualizer blurred and dark. With Reduce Motion the colors stay still.")
            }
            Section {
                Picker("Open at launch", selection: $prefs.appearance.startPage) {
                    Text("Home").tag(AppearanceSettings.StartPage.home)
                    Text("Albums").tag(AppearanceSettings.StartPage.albums)
                    Text("Songs").tag(AppearanceSettings.StartPage.songs)
                    Text("Last Opened Page").tag(AppearanceSettings.StartPage.last)
                }
            } footer: {
                SettingsFooter("The page the window shows when MusicSync opens.")
            }
            Section {
                Picker("Rows", selection: $prefs.appearance.listDensity) {
                    Text("Comfortable").tag(AppearanceSettings.ListDensity.comfortable)
                    Text("Compact").tag(AppearanceSettings.ListDensity.compact)
                }
                .pickerStyle(.segmented)
                ForEach(AppearanceSettings.SongColumn.allCases, id: \.self) { column in
                    Toggle(column.title, isOn: Binding(get: { prefs.appearance.songColumns.contains(column) }, set: {
                        if $0 { prefs.appearance.songColumns.insert(column) } else { prefs.appearance.songColumns.remove(column) }
                    }))
                }
            } header: {
                Text("Song Lists")
            } footer: {
                SettingsFooter("Extra details next to the song length on album, playlist and song pages. To choose the columns of the Songs page, Control-click its header.")
            }
            Section {
                ForEach(SidebarItem.editable, id: \.self) { item in
                    Toggle(isOn: Binding(get: { item.isShown }, set: { prefs.appearance.setShown(item.key ?? "", $0) })) {
                        Label { Text(item.title) } icon: { Image(systemName: item.symbol).foregroundStyle(Color.musicAccent) }
                    }
                }
            } header: {
                Text("Sidebar")
            } footer: {
                SettingsFooter("Hidden pages stay open until you choose another one. Search and the iPod are always shown.")
            }
        }
        .formStyle(.grouped)
        .settingsPageSize(width: 480)
    }
}

/// Colored circles, as in System Settings > Appearance.
private struct AccentPicker: View {
    @Binding var selection: AppearanceSettings.Accent

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppearanceSettings.Accent.allCases, id: \.self) { accent in
                Button { selection = accent } label: {
                    Circle().fill(fill(accent)).frame(width: 18, height: 18)
                        .overlay { if selection == accent { Circle().fill(.white).frame(width: 6, height: 6) } }
                        .padding(2)
                        .overlay { Circle().strokeBorder(selection == accent ? accent.color : .clear, lineWidth: 1.5) }
                }
                .buttonStyle(HitAreaButtonStyle())
                .help(accent.title)
                .accessibilityLabel(accent.title)
                .accessibilityAddTraits(selection == accent ? .isSelected : [])
            }
        }
    }

    /// Album Color shows all colors, as the multicolor accent of System Settings.
    private func fill(_ accent: AppearanceSettings.Accent) -> AnyShapeStyle {
        accent == .album ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
            : AnyShapeStyle(accent.color.gradient)
    }
}

extension AppearanceSettings.SongColumn {
    var title: String {
        switch self {
        case .rating: "Show rating"
        case .plays: "Show play count"
        case .format: "Show format and bitrate"
        }
    }
}
