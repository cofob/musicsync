import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keys and defaults of the visualizer options; the window and Settings > Visualizer share them through `@AppStorage(store: .app)`.
enum VisualizerSettings {
    static let mode = "visualizerMode"
    static let lyrics = "visualizerLyrics"
    static let announce = "visualizerAnnounce"
    /// Change with the parts of the song (analyzed); off by default.
    static let sections = "visualizerSections"
    static let cycle = "visualizerCycle"
    static let cycleSeconds = "visualizerCycleSeconds"
    static let blend = "visualizerBlend"
    static let shuffle = "visualizerShuffle"
    static let builtIn = "visualizerBuiltIn"
    static let quality = "visualizerQuality"
    static let peaks = "visualizerPeaks"
    static let segmented = "visualizerSegmented"
    static let falloff = "visualizerFalloff"

    /// Copies .milk and .json presets into the presets folder, replacing files of the same name. Returns how many it copied.
    @MainActor static func importPresets() -> Int {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "milk") ?? .data, .json]
        panel.message = "Choose MilkDrop (.milk) or butterchurn (.json) presets"
        guard panel.runModal() == .OK else { return 0 }
        let folder = MilkDrop.userFolder
        return panel.urls.filter { url in
            let target = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            // A new .milk file gets converted again.
            if url.pathExtension == "milk" { try? FileManager.default.removeItem(at: target.deletingPathExtension().appendingPathExtension("json")) }
            return (try? FileManager.default.copyItem(at: url, to: target)) != nil
        }.count
    }

    /// Names of the presets in the folder, a .milk file and its converted .json counted once.
    static func userPresets() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: MilkDrop.userFolder, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { ["milk", "json"].contains($0.pathExtension) }.map { $0.deletingPathExtension().lastPathComponent }).sorted()
    }
}

/// When the visualizer changes on its own: MilkDrop shows another preset; with song parts the spectrum and the
/// oscilloscope also take new colors. One choice, so a timer and song parts cannot both seem to be on.
enum VisualizerChange: String, CaseIterable, Identifiable {
    case never, timer, parts
    var id: Self { self }

    func title(every seconds: Double) -> String {
        switch self {
        case .never: "Never"
        case .timer: "Every \(Int(seconds)) Seconds"
        case .parts: "With Song Parts"
        }
    }

    /// In Settings, where the interval has its own row.
    var settingsTitle: String {
        switch self {
        case .never: "Never"
        case .timer: "On a timer"
        case .parts: "With song parts"
        }
    }

    /// Kept in the two older switches, so earlier settings keep their meaning. Song parts use the timer
    /// while the song is not analyzed yet or has no clear parts.
    static func binding(cycle: Binding<Bool>, parts: Binding<Bool>) -> Binding<VisualizerChange> {
        Binding(get: { parts.wrappedValue ? .parts : cycle.wrappedValue ? .timer : .never },
                set: { cycle.wrappedValue = $0 != .never; parts.wrappedValue = $0 == .parts })
    }
}

/// Settings > Visualizer.
struct VisualizerSettingsView: View {
    @AppStorage(VisualizerSettings.mode, store: .app) private var mode = VisualizerMode.spectrum
    @AppStorage(VisualizerSettings.lyrics, store: .app) private var lyrics = true
    @AppStorage(VisualizerSettings.announce, store: .app) private var announce = true
    @AppStorage(VisualizerSettings.sections, store: .app) private var sections = false
    @AppStorage(VisualizerSettings.cycle, store: .app) private var cycle = true
    @AppStorage(VisualizerSettings.cycleSeconds, store: .app) private var cycleSeconds = 20.0
    @AppStorage(VisualizerSettings.blend, store: .app) private var blend = 2.7
    @AppStorage(VisualizerSettings.shuffle, store: .app) private var shuffle = true
    @AppStorage(VisualizerSettings.builtIn, store: .app) private var builtIn = true
    @AppStorage(VisualizerSettings.quality, store: .app) private var quality = 1.0
    @AppStorage(VisualizerSettings.peaks, store: .app) private var peaks = true
    @AppStorage(VisualizerSettings.segmented, store: .app) private var segmented = true
    @AppStorage(VisualizerSettings.falloff, store: .app) private var falloff = 1.6
    @Environment(\.openWindow) private var openWindow
    @State private var presets = VisualizerSettings.userPresets()

    var body: some View {
        let change = VisualizerChange.binding(cycle: $cycle, parts: $sections)
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
                    Picker(change.wrappedValue == .parts ? "Until a song is analyzed, every" : "Every", selection: $cycleSeconds) {
                        ForEach([10.0, 20, 30, 60, 120], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                }
            } header: {
                Text("Changes")
            } footer: {
                SettingsFooter("MilkDrop shows another preset. With Song Parts each song is analyzed to find where its parts start (verse, chorus…); there MilkDrop changes the preset and the spectrum and oscilloscope their colors. Streamed songs are downloaded once more for this; the results are kept.")
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
                Toggle("Include built-in presets", isOn: $builtIn)
                    .disabled(presets.isEmpty)
                LabeledContent("Your presets", value: presets.isEmpty ? "None" : "\(presets.count)")
                HStack {
                    Button("Import Presets…") { _ = VisualizerSettings.importPresets(); presets = VisualizerSettings.userPresets() }
                    Button("Show in Finder") { NSWorkspace.shared.open(MilkDrop.userFolder) }
                }
            } header: {
                Text("Presets")
            } footer: {
                SettingsFooter("MilkDrop (.milk) presets from Winamp, and butterchurn (.json) presets. A .milk preset is converted the first time MilkDrop shows; some shaders do not convert and the preset is skipped.")
            }
        }
        .formStyle(.grouped)
        .onAppear { presets = VisualizerSettings.userPresets() }
    }
}
