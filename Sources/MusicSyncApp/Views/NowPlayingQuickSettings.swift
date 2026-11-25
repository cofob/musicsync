import SwiftUI
import Preferences

/// The Now Playing settings in a menu in the bottom left corner: the background and the visualizer's look.
struct NowPlayingQuickSettings: View {
    @AppStorage(VisualizerSettings.mode, store: .app) private var mode = VisualizerMode.milkdrop
    @AppStorage(VisualizerSettings.lyrics, store: .app) private var lyrics = true
    @AppStorage(VisualizerSettings.cycle, store: .app) private var cycle = true
    @AppStorage(VisualizerSettings.sections, store: .app) private var sections = false
    @AppStorage(VisualizerSettings.mood, store: .app) private var mood = false
    @AppStorage(VisualizerSettings.reduceFlashing, store: .app) private var reduceFlashing: Bool?
    @AppStorage(VisualizerSettings.limitBrightness, store: .app) private var limitBrightness: Bool?

    var body: some View {
        @Bindable var prefs = AppPreferences.shared
        Menu {
            Picker("Background", selection: $prefs.appearance.nowPlayingBackground) {
                Text("Animated Cover Colors").tag(AppearanceSettings.NowPlayingBackground.animated)
                Text("Static Cover Colors").tag(AppearanceSettings.NowPlayingBackground.artwork)
                Text("Plain").tag(AppearanceSettings.NowPlayingBackground.plain)
                Text("Blurred Visualizer").tag(AppearanceSettings.NowPlayingBackground.visualizer)
                Text("Music Video").tag(AppearanceSettings.NowPlayingBackground.video)
            }
            Section("Visualizer") {
                Picker("Style", selection: $mode) { ForEach(VisualizerMode.allCases) { Text($0.title).tag($0) } }
                Picker("Change Presets", selection: VisualizerChange.binding(cycle: $cycle, parts: $sections, mood: $mood)) {
                    ForEach(VisualizerChange.allCases) { Text($0.settingsTitle).tag($0) }
                }
                Toggle("Show Synced Lyrics", isOn: $lyrics)
                Toggle("Reduce Flashing", isOn: Binding(get: { reduceFlashing ?? VisualizerSettings.systemReducesMotion }, set: { reduceFlashing = $0 }))
                Toggle("Limit Brightness Changes", isOn: Binding(get: { limitBrightness ?? VisualizerSettings.systemReducesMotion }, set: { limitBrightness = $0 }))
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(HitAreaButtonStyle(width: 34, height: 30)).font(.system(size: 15, weight: .semibold))
        .help("Now Playing Settings")
        .accessibilityLabel("Now Playing Settings")
    }
}
