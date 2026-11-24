import MilkDropKit
import SwiftUI
import UniformTypeIdentifiers

/// Keys and defaults of the visualizer options; the window and Settings > Visualizer share them through `@AppStorage(store: .app)`.
enum VisualizerSettings {
    static let mode = "visualizerMode"
    static let lyrics = "visualizerLyrics"
    static let announce = "visualizerAnnounce"
    /// Change with the parts of the song (analyzed); off by default.
    static let sections = "visualizerSections"
    /// With song parts, pick presets whose mood matches the part's (`Mood`); off by default.
    static let mood = "visualizerMood"
    /// Leave out presets that flash too much; unset follows the system's Reduce Motion.
    static let reduceFlashing = "visualizerReduceFlashing"
    static let cycle = "visualizerCycle"
    static let cycleSeconds = "visualizerCycleSeconds"
    static let blend = "visualizerBlend"
    static let shuffle = "visualizerShuffle"
    static let builtIn = "visualizerBuiltIn"
    static let quality = "visualizerQuality"
    static let peaks = "visualizerPeaks"
    static let segmented = "visualizerSegmented"
    static let falloff = "visualizerFalloff"

    /// Reduce Motion in the system's accessibility settings.
    @MainActor static var systemReducesMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// The setting, or the system's Reduce Motion while the user has not chosen.
    @MainActor static var reducesFlashing: Bool { UserDefaults.app.object(forKey: reduceFlashing) as? Bool ?? systemReducesMotion }

    static let presetTypes = [UTType(filenameExtension: "milk") ?? .data]
    /// Posted when presets were imported, downloaded or removed, so an open visualizer reads its folders again.
    static let presetsChanged = Notification.Name("visualizerPresetsChanged")

    #if os(macOS)
    /// Asks for presets, then imports them.
    @MainActor static func importPresets() -> Int {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = presetTypes
        panel.message = "Choose MilkDrop (.milk) presets"
        guard panel.runModal() == .OK else { return 0 }
        return importPresets(panel.urls)
    }
    #endif

    /// Copies .milk presets into the presets folder, replacing files of the same name. Returns how many it copied.
    @MainActor static func importPresets(_ urls: [URL]) -> Int {
        let folder = MilkDrop.userFolder
        let count = urls.filter { url in
            let scoped = url.startAccessingSecurityScopedResource()  // a file picked in Files on iPad
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let target = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            return (try? FileManager.default.copyItem(at: url, to: target)) != nil
        }.count
        NotificationCenter.default.post(name: presetsChanged, object: nil)
        return count
    }

    /// Names of the .milk presets in the user's folder.
    static func userPresets() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: MilkDrop.userFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "milk" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}

extension View {
    /// Picks presets in Files and imports them; `done` runs when any came in.
    func presetImporter(isPresented: Binding<Bool>, done: @escaping () -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: VisualizerSettings.presetTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, VisualizerSettings.importPresets(urls) > 0 { done() }
        }
    }
}

/// When the visualizer changes on its own: MilkDrop shows another preset; with song parts the spectrum and the
/// oscilloscope also take new colors. One choice, so a timer and song parts cannot both seem to be on.
/// With the mood MilkDrop picks the preset that looks like the part sounds.
enum VisualizerChange: String, CaseIterable, Identifiable {
    case never, timer, parts, mood
    var id: Self { self }

    func title(every seconds: Double) -> String {
        switch self {
        case .never: "Never"
        case .timer: "Every \(Int(seconds)) Seconds"
        case .parts: "With Song Parts"
        case .mood: "Match the Mood"
        }
    }

    /// In Settings, where the interval has its own row.
    var settingsTitle: String {
        switch self {
        case .never: "Never"
        case .timer: "On a timer"
        case .parts: "With song parts"
        case .mood: "Match the mood"
        }
    }

    /// Kept in the older switches, so earlier settings keep their meaning; the mood is song parts with a third one.
    /// Song parts use the timer while the song is not analyzed yet or has no clear parts.
    static func binding(cycle: Binding<Bool>, parts: Binding<Bool>, mood: Binding<Bool>) -> Binding<VisualizerChange> {
        Binding(get: { parts.wrappedValue ? (mood.wrappedValue ? .mood : .parts) : cycle.wrappedValue ? .timer : .never },
                set: { cycle.wrappedValue = $0 != .never; parts.wrappedValue = $0 == .parts || $0 == .mood; mood.wrappedValue = $0 == .mood })
    }
}

/// Settings > Visualizer.
struct VisualizerSettingsView: View {
    @AppStorage(VisualizerSettings.mode, store: .app) private var mode = VisualizerMode.milkdrop
    @AppStorage(VisualizerSettings.lyrics, store: .app) private var lyrics = true
    @AppStorage(VisualizerSettings.announce, store: .app) private var announce = true
    @AppStorage(VisualizerSettings.sections, store: .app) private var sections = false
    @AppStorage(VisualizerSettings.mood, store: .app) private var mood = false
    @AppStorage(VisualizerSettings.reduceFlashing, store: .app) private var reduceFlashing: Bool?
    @AppStorage(VisualizerSettings.cycle, store: .app) private var cycle = true
    @AppStorage(VisualizerSettings.cycleSeconds, store: .app) private var cycleSeconds = 20.0
    @AppStorage(VisualizerSettings.blend, store: .app) private var blend = 2.7
    @AppStorage(VisualizerSettings.shuffle, store: .app) private var shuffle = true
    @AppStorage(VisualizerSettings.builtIn, store: .app) private var builtIn = true
    @AppStorage(VisualizerSettings.quality, store: .app) private var quality = 1.0
    @AppStorage(VisualizerSettings.peaks, store: .app) private var peaks = true
    @AppStorage(VisualizerSettings.segmented, store: .app) private var segmented = true
    @AppStorage(VisualizerSettings.falloff, store: .app) private var falloff = 1.6
    private var openWindow = OpenToolWindow()
    @State private var presets = VisualizerSettings.userPresets()
    @State private var importing = false
    @State private var packs = PresetPacks()

    var body: some View {
        let change = VisualizerChange.binding(cycle: $cycle, parts: $sections, mood: $mood)
        Form {
            Section {
                Picker("Style", selection: $mode) { ForEach(VisualizerMode.allCases) { Text($0.title).tag($0) } }
                Toggle("Show synced lyrics", isOn: $lyrics)
                Toggle("Announce songs", isOn: $announce)
                Button("Show Visualizer") { openWindow(id: VisualizerView.windowID) }
            } footer: {
                SettingsFooter("Window > Visualizer (⌘T), or the waveform button in Now Playing and the MiniPlayer. Announce Songs shows the artist and title when a song starts.")
            }
            Section {
                Picker("Change", selection: change) {
                    ForEach(VisualizerChange.allCases) { Text($0.settingsTitle).tag($0) }
                }
                if change.wrappedValue != .never {
                    Picker([.parts, .mood].contains(change.wrappedValue) ? "Until a song is analyzed, every" : "Every", selection: $cycleSeconds) {
                        ForEach([10.0, 20, 30, 60, 120], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                }
            } header: {
                Text("Changes")
            } footer: {
                SettingsFooter("MilkDrop shows another preset. With Song Parts each song is analyzed to find where its parts start (verse, chorus…); there MilkDrop changes the preset and the spectrum and oscilloscope their colors. Match the Mood also judges how each part sounds (energy, brightness, tension) and shows a preset that looks like that; presets get their mood when they are measured, in the background. Streamed songs are downloaded once more for this; the results are kept.")
            }
            Section("Spectrum") {
                Toggle("Peak caps", isOn: $peaks)
                Toggle("Segmented bars", isOn: $segmented)
                LabeledContent("Bar fall speed") {
                    Slider(value: $falloff, in: 0.4...4) { EmptyView() } minimumValueLabel: { Text("Slow").foregroundStyle(.secondary) } maximumValueLabel: { Text("Fast").foregroundStyle(.secondary) }
                }
            }
            Section {
                Picker("Next preset", selection: $shuffle) {
                    Text("Random").tag(true)
                    Text("Alphabetical").tag(false)
                }
                LabeledContent("Blend time") {
                    Slider(value: $blend, in: 0...10, step: 0.5) { EmptyView() } minimumValueLabel: { Text("Cut").foregroundStyle(.secondary) } maximumValueLabel: { Text("10 s").foregroundStyle(.secondary) }
                }
                Picker("Quality", selection: $quality) {
                    Text("Low").tag(0.5)
                    Text("Normal").tag(1.0)
                    Text("Retina").tag(2.0)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("MilkDrop")
            } footer: {
                SettingsFooter("Next Preset is used by the changes above and the Next button. Blend time is how long two presets mix when the preset changes. Retina quality renders every screen pixel and uses more GPU.")
            }
            Section {
                Toggle("Reduce flashing", isOn: Binding(get: { reduceFlashing ?? VisualizerSettings.systemReducesMotion }, set: { reduceFlashing = $0 }))
                Toggle("Include built-in presets", isOn: $builtIn)
                    .disabled(presets.isEmpty && packs.installed.isEmpty)
                LabeledContent("Your presets", value: presets.isEmpty ? "None" : "\(presets.count)")
                HStack {
                    #if os(macOS)
                    Button("Import Presets…") { _ = VisualizerSettings.importPresets(); presets = VisualizerSettings.userPresets() }
                    Button("Show in Finder") { NSWorkspace.shared.open(MilkDrop.userFolder) }
                    #else
                    Button("Import Presets…") { importing = true }
                        .presetImporter(isPresented: $importing) { presets = VisualizerSettings.userPresets() }
                    #endif
                }
            } header: {
                Text("Presets")
            } footer: {
                SettingsFooter("MilkDrop (.milk) presets from Winamp. A preset whose shaders do not compile is skipped. Reduce Flashing also skips presets that flash too much: each is rendered for four seconds and checked against the photosensitivity limits (three flashes a second over a quarter of the screen). It follows the system's Reduce Motion until you choose, and presets not checked yet show once they are.")
            }
            PresetPacksSection(packs: packs)
        }
        .formStyle(.grouped)
        .onAppear { presets = VisualizerSettings.userPresets(); packs.refresh() }
    }
}
