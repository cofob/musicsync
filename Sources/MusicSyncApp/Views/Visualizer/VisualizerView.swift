import AppKit
import Subsonic
import SwiftUI

enum VisualizerMode: String, CaseIterable, Identifiable {
    case spectrum, scope, milkdrop
    var id: Self { self }
    var title: String {
        switch self {
        case .spectrum: "Spectrum"
        case .scope: "Oscilloscope"
        case .milkdrop: "MilkDrop"
        }
    }
}

/// The playing music as Winamp and AIMP showed it: spectrum bars, an oscilloscope or MilkDrop presets.
/// Window > Visualizer (⌘T), full bleed in Now Playing and in place of the MiniPlayer cover. Controls show on hover;
/// `compact` (the MiniPlayer) has its own controls instead. Settings > Visualizer has all options.
struct VisualizerView: View {
    static let windowID = "visualizer"
    var compact = false

    @Environment(AppModel.self) private var model
    @AppStorage(VisualizerSettings.mode, store: .app) private var mode = VisualizerMode.spectrum
    @AppStorage(VisualizerSettings.cycle, store: .app) private var cycles = true
    @AppStorage(VisualizerSettings.lyrics, store: .app) private var showsLyrics = true
    @AppStorage(VisualizerSettings.announce, store: .app) private var announces = true
    @AppStorage(VisualizerSettings.cycleSeconds, store: .app) private var cycleSeconds = 20.0
    @AppStorage(VisualizerSettings.blend, store: .app) private var blend = 2.7
    @AppStorage(VisualizerSettings.shuffle, store: .app) private var shuffle = true
    @AppStorage(VisualizerSettings.builtIn, store: .app) private var builtIn = true
    @AppStorage(VisualizerSettings.quality, store: .app) private var quality = 1.0
    @State private var lyrics: Lyrics?
    @State private var milkDrop = MilkDrop()
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    @State private var overControls = false
    /// The window this view put in full screen; it leaves full screen when the view goes (Now Playing closes).
    @State private var fullScreenWindow: NSWindow?

    var body: some View {
        let player = model.player
        let song: Song? = if case .server(let s)? = player.current { s } else { nil }
        let line = showsLyrics ? lyrics?.line(at: player.elapsed) : nil
        ZStack {
            Color.black
            switch mode {
            case .spectrum: SpectrumVisualizer(player: player)
            case .scope: ScopeVisualizer(player: player)
            case .milkdrop: MilkDropView(player: player, milkDrop: milkDrop)
            }
            if mode != .milkdrop, let lyrics, let line { VisualizerLyrics(lyrics: lyrics, current: line) }
            // Takes the mouse from the web view: hover, double-click and keys stay here.
            if !compact {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(count: 2) { toggleFullScreen() }
            }
        }
        .overlay(alignment: .bottom) { if hovering, !compact { controls.transition(.opacity) } }
        .onContinuousHover { phase in if case .active = phase { show() } else { hovering = false } }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .focusable().focusEffectDisabled()
        .onKeyPress(.leftArrow) { milkDrop.step(-1); return mode == .milkdrop ? .handled : .ignored }
        .onKeyPress(.rightArrow) { milkDrop.step(1); return mode == .milkdrop ? .handled : .ignored }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onAppear { player.visualizers += 1 }
        .onChange(of: hovering) { if !compact { model.visualizerIdle = !hovering } }
        .onDisappear {
            if !compact { model.visualizerIdle = false }
            player.visualizers -= 1
            if let window = fullScreenWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
        .onChange(of: config, initial: true) { milkDrop.configure(config) }
        // MilkDrop draws the song title and the lyrics into the preset, as it announced songs in Winamp.
        .onChange(of: player.current?.id, initial: true) {
            guard announces, let item = player.current else { return }
            milkDrop.title([item.artist, item.title].compactMap { $0 }.joined(separator: " - "))
        }
        .onChange(of: line) {
            guard let line, let lyrics, !lyrics.lines[line].text.isEmpty else { return }
            // The line stays until the next one starts.
            let start = lyrics.lines[line].start ?? 0, next = lyrics.lines.dropFirst(line + 1).first?.start ?? start + 4
            milkDrop.title(lyrics.lines[line].text, seconds: min(max(next - start - 0.2, 2), 10))
        }
        .task(id: song?.id) {
            lyrics = nil
            guard let song else { return }
            let found = await model.lyrics(for: song)
            if !Task.isCancelled { lyrics = found }
        }
    }

    /// The player as usual (song, scrubber, transport) over the visualizer buttons.
    private var controls: some View {
        let player = model.player
        return VStack(spacing: 10) {
            VStack(spacing: 1) {
                Text(player.current?.title ?? "Not Playing").font(.headline)
                Text([player.current?.artist, mode == .milkdrop ? milkDrop.current : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(1)
            ScrubBar(tint: .white)
            TransportControls(scale: 0.9, spacing: 14)
            visualizerButtons
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: 560)
        // Dark, not glass: glass takes the colors of the bars under it.
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(.horizontal, 24).padding(.bottom, 20)
        .onHover { overControls = $0 }
    }

    private var visualizerButtons: some View {
        HStack(spacing: 4) {
            Picker("Mode", selection: $mode) { ForEach(VisualizerMode.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            Spacer(minLength: 8)
            if mode == .milkdrop {
                Button("Previous Preset", systemImage: "chevron.left") { milkDrop.step(-1) }
                Menu("Presets", systemImage: "sparkles") {
                    ForEach(milkDrop.presets, id: \.self) { name in Button(name) { milkDrop.select(name) } }
                    Divider()
                    if !milkDrop.failed.isEmpty { Text("Not converted: \(milkDrop.failed.joined(separator: ", "))") }
                    Button("Import Presets…") { if VisualizerSettings.importPresets() > 0 { milkDrop.loadUserPresets() } }
                    Button("Show Presets Folder") { NSWorkspace.shared.open(MilkDrop.userFolder) }
                    SettingsLink { Text("Visualizer Settings…") }
                }
                .menuIndicator(.hidden).fixedSize()
                .help("Presets; import MilkDrop .milk files here")
                Button("Next Preset", systemImage: "chevron.right") { milkDrop.step(1) }
                Button("Random Preset", systemImage: "shuffle") { milkDrop.random() }
                Toggle("Change Presets", systemImage: "timer", isOn: $cycles).toggleStyle(.button)
                    .help("Change the preset every \(Int(cycleSeconds)) seconds")
                Toggle("Announce Songs", systemImage: "textformat", isOn: $announces).toggleStyle(.button)
                    .help("Show the artist and title when a song starts")
            }
            Toggle("Lyrics", systemImage: "quote.bubble", isOn: $showsLyrics).toggleStyle(.button)
                .help("Show synced lyrics")
            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { toggleFullScreen() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(HitAreaButtonStyle(width: 28, height: 26))
        .font(.system(size: 13, weight: .semibold))
    }

    /// Options for the MilkDrop page, see `ms.configure` in `Resources/Visualizer/index.html`.
    private var config: String {
        let options: [String: Any] = ["cycle": cycles, "seconds": cycleSeconds, "blend": blend, "shuffle": shuffle, "builtIn": builtIn, "quality": quality]
        return (try? JSONSerialization.data(withJSONObject: options, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func toggleFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        fullScreenWindow = window.styleMask.contains(.fullScreen) ? nil : window
        window.toggleFullScreen(nil)
    }

    /// Shows the controls; they and the cursor go away after 2 s without mouse moves.
    private func show() {
        withAnimation(.easeOut(duration: 0.2)) { hovering = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !overControls else { return }
            withAnimation(.easeOut(duration: 0.3)) { hovering = false }
            if !compact { NSCursor.setHiddenUntilMouseMoves(true) }  // the cursor goes with the controls
        }
    }
}

/// Window > Visualizer, ⌘T as in Apple Music.
struct VisualizerMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Visualizer") { openWindow(id: VisualizerView.windowID) }
            .keyboardShortcut("t")
    }
}
