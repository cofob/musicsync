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
    /// Inside Now Playing: its buttons hide and stay with this view's controls (`AppModel.visualizerIdle`, `visualizerHold`).
    var inNowPlaying = false
    /// Off while Now Playing shows the lyrics in its panel: they would show twice.
    var showsOverlayLyrics = true
    /// Room the player keeps free at the sides, for the Now Playing panel and buttons.
    var insets = EdgeInsets()

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
    @AppStorage(VisualizerSettings.sections, store: .app) private var followsSections = false
    /// Color scheme of the spectrum and the oscilloscope; the next one at each new part of the song.
    @State private var palette = 0
    @State private var lyrics: Lyrics?
    @State private var milkDrop = MilkDrop()
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    @State private var overControls = false
    /// The window this view put in full screen; it leaves full screen when the view goes (Now Playing closes).
    #if os(macOS)
    @State private var fullScreenWindow: NSWindow?
    #else
    @State private var importing = false
    #endif

    var body: some View {
        let player = model.player
        let song: Song? = if case .server(let s)? = player.current { s } else { nil }
        let line = showsLyrics && showsOverlayLyrics ? lyrics?.line(at: player.elapsed) : nil
        // The part of the song playing now: −1 before the first boundary, nil while not followed or not analyzed.
        let section = followsSections ? player.sections.map { s in s.lastIndex { $0 <= player.elapsed } ?? -1 } : nil
        ZStack {
            Color.black
            switch mode {
            case .spectrum: SpectrumVisualizer(player: player, palette: palette)
            case .scope: ScopeVisualizer(player: player, palette: palette)
            case .milkdrop: MilkDropView(player: player, milkDrop: milkDrop)
            }
            if mode != .milkdrop, let lyrics, let line { VisualizerLyrics(lyrics: lyrics, current: line) }
            if model.jukebox.isActive, !compact {
                Text("Playing on the server: there is no sound here to show.").font(.headline).foregroundStyle(.white.opacity(0.6))
            }
            // Takes the mouse from the web view: hover, double-click and keys stay here.
            if !compact {
                Color.clear.contentShape(Rectangle())
                    #if os(macOS)
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    #else
                    .onTapGesture { show() }  // no hover on a touch screen
                    #endif
            }
        }
        .overlay(alignment: .bottom) { if hovering, !compact { controls.transition(.opacity) } }
        // Leaving does not hide at once: Now Playing's own buttons lie over this view, and hiding them under the mouse
        // would make them flicker and miss clicks. The idle timer in `show` hides everything.
        .onContinuousHover { phase in if case .active = phase { show() } }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .focusable().focusEffectDisabled()
        .onKeyPress(.leftArrow) { milkDrop.step(-1); return mode == .milkdrop ? .handled : .ignored }
        .onKeyPress(.rightArrow) { milkDrop.step(1); return mode == .milkdrop ? .handled : .ignored }
        .onKeyPress("f") { toggleFullScreen(); return .handled }
        .onAppear { player.visualizers += 1 }
        .onChange(of: hovering) { if inNowPlaying { model.visualizerIdle = !hovering } }
        .onChange(of: model.visualizerHold) { if inNowPlaying { show() } }
        .onDisappear {
            if inNowPlaying { model.visualizerIdle = false; model.visualizerHold = false }
            player.visualizers -= 1
            #if os(macOS)
            if let window = fullScreenWindow, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            #endif
        }
        .onChange(of: config, initial: true) { milkDrop.configure(config) }
        // MilkDrop draws the song title and the lyrics into the preset, as it announced songs in Winamp.
        // Only moving on into the next part counts, not a seek.
        .onChange(of: section) { old, new in
            if let old, let new, new == old + 1, player.isPlaying { partStarted() }
        }
        .onChange(of: followsSections) { player.analyzeUpcoming() }
        .onChange(of: player.current?.id, initial: true) { old, _ in
            if followsSections, old != nil, old != player.current?.id { partStarted() }  // a new song is a new part too
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
            HStack(spacing: 8) {
                favoriteButton
                VStack(spacing: 1) {
                    Text(player.current?.title ?? "Not Playing").font(.headline)
                    Text([player.isMixing ? "AutoMix" : nil, player.current?.artist, mode == .milkdrop ? milkDrop.current : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1).frame(maxWidth: .infinity)
                songMenu
            }
            .labelStyle(.iconOnly).buttonStyle(VisualizerButtonStyle()).font(.system(size: 13, weight: .semibold))
            ScrubBar(tint: .white)
            TransportControls(scale: 0.9, spacing: 14)
            // Narrow: the modes become a menu, then Lyrics only an icon.
            ViewThatFits(in: .horizontal) {
                visualizerButtons(menuModes: false, lyricsTitle: true)
                visualizerButtons(menuModes: true, lyricsTitle: true)
                visualizerButtons(menuModes: true, lyricsTitle: false)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: 640)
        // Dark, not glass: glass takes the colors of the bars under it.
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(.horizontal, 24).padding(.bottom, 20)
        .padding(.leading, insets.leading).padding(.trailing, insets.trailing)
        .onHover { overControls = $0 }
    }

    /// Star and "•••" of the song, as Now Playing has them; empty space for other items keeps the title centered.
    @ViewBuilder private var favoriteButton: some View {
        if case .server(let song)? = model.player.current {
            let starred = model.isStarred(song)
            Button(starred ? "Undo Favorite" : "Favorite", systemImage: starred ? "star.fill" : "star") { model.toggleStar(song) }
                .accessibilityLabel("Favorite").accessibilityValue(starred ? "On" : "Off")
        } else {
            Color.clear.frame(width: 28, height: 26)
        }
    }

    @ViewBuilder private var songMenu: some View {
        if case .server(let song)? = model.player.current {
            Menu { SongMenuItems(song: song, inQueue: false) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize().help("More")
        } else {
            Color.clear.frame(width: 28, height: 26)
        }
    }

    private func visualizerButtons(menuModes: Bool, lyricsTitle: Bool) -> some View {
        HStack(spacing: 4) {
            Group {
                if menuModes {
                    Picker("Mode", selection: $mode) { ForEach(VisualizerMode.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                } else {
                    Picker("Mode", selection: $mode) { ForEach(VisualizerMode.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .controlSize(.small)
            Spacer(minLength: 8)
            if mode == .milkdrop {
                Button("Previous Preset", systemImage: "chevron.left") { milkDrop.step(-1) }.help("Previous preset")
                presetsMenu
                Button("Next Preset", systemImage: "chevron.right") { milkDrop.step(1) }.help("Next preset")
            }
            Button { showsLyrics.toggle() } label: {
                if lyricsTitle { Label("Lyrics", systemImage: "quote.bubble").labelStyle(.titleAndIcon) } else { Label("Lyrics", systemImage: "quote.bubble") }
            }
                .buttonStyle(VisualizerButtonStyle(isOn: showsLyrics && showsOverlayLyrics, wide: lyricsTitle))
                .disabled(!showsOverlayLyrics)
                .help(showsOverlayLyrics ? "Show synced lyrics over the visualizer" : "The lyrics show in the panel")
                .accessibilityValue(showsLyrics ? "On" : "Off")
            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { toggleFullScreen() }.help("Full screen")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(VisualizerButtonStyle())
        .font(.system(size: 13, weight: .semibold))
    }

    /// Every MilkDrop option with its name: the bar keeps only previous, this menu and next.
    private var presetsMenu: some View {
        Menu {
            Button("Random Preset") { milkDrop.random() }
            Menu("Choose Preset") { ForEach(milkDrop.presets, id: \.self) { name in Button(name) { milkDrop.select(name) } } }
            Divider()
            Picker("Change Presets", selection: VisualizerChange.binding(cycle: $cycles, parts: $followsSections)) {
                ForEach(VisualizerChange.allCases) { Text($0.title(every: cycleSeconds)).tag($0) }
            }
            Toggle("Announce Songs", isOn: $announces)
            Divider()
            if !milkDrop.failed.isEmpty { Text("Not converted: \(milkDrop.failed.joined(separator: ", "))") }
            #if os(macOS)
            Button("Import Presets…") { if VisualizerSettings.importPresets() > 0 { milkDrop.loadUserPresets() } }
            Button("Show Presets Folder") { NSWorkspace.shared.open(MilkDrop.userFolder) }
            #else
            Button("Import Presets…") { importing = true }
            #endif
            SettingsLink { Text("Visualizer Settings…") }
        } label: {
            Label("Presets", systemImage: "sparkles").labelStyle(.titleAndIcon)
        }
        .menuStyle(.button).menuIndicator(.hidden).fixedSize()
        #if os(iOS)
        .presetImporter(isPresented: $importing) { milkDrop.loadUserPresets() }
        #endif
        .buttonStyle(VisualizerButtonStyle(wide: true))
        .help("Preset options; import MilkDrop .milk files here")
    }

    /// Options for the MilkDrop page, see `ms.configure` in `Resources/Visualizer/index.html`.
    private var config: String {
        // The timer stands by while the song's parts are known.
        let byParts = followsSections && !(model.player.sections ?? []).isEmpty
        let options: [String: Any] = ["cycle": cycles && !byParts, "seconds": cycleSeconds, "blend": blend, "shuffle": shuffle, "builtIn": builtIn, "quality": quality]
        return (try? JSONSerialization.data(withJSONObject: options, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// A new part of the song: MilkDrop shows the next preset (compiled ahead), the others their next colors.
    private func partStarted() {
        if mode == .milkdrop { shuffle ? milkDrop.random() : milkDrop.step(1) } else { palette += 1 }
    }

    private func toggleFullScreen() {
        #if os(macOS)
        guard let window = NSApp.keyWindow else { return }
        fullScreenWindow = window.styleMask.contains(.fullScreen) ? nil : window
        window.toggleFullScreen(nil)
        #endif
    }

    /// Shows the controls; they and the cursor go away after 2 s without mouse moves.
    private func show() {
        withAnimation(.easeOut(duration: 0.2)) { hovering = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !overControls, !(inNowPlaying && model.visualizerHold) else { return }
            withAnimation(.easeOut(duration: 0.3)) { hovering = false }
            #if os(macOS)
            if !compact { NSCursor.setHiddenUntilMouseMoves(true) }
            #endif  // the cursor goes with the controls
        }
    }
}

/// Window > Visualizer, ⌘T.
struct VisualizerMenuItem: View {
    private var openWindow = OpenToolWindow()

    var body: some View {
        Button("Visualizer") { openWindow(id: VisualizerView.windowID) }
            .keyboardShortcut("t")
    }
}


/// Round icon buttons of the visualizer: a light circle under the mouse, darker while pressed, white while on.
struct VisualizerButtonStyle: ButtonStyle {
    var isOn = false
    /// Room for a title next to the icon.
    var wide = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = isOn ? .white.opacity(configuration.isPressed ? 0.7 : 0.9)
            : .white.opacity(configuration.isPressed ? 0.3 : hovering ? 0.15 : 0)
        configuration.label
            .foregroundStyle(isOn ? Color.black : .white)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, wide ? 10 : 0)
            .frame(minWidth: 28, minHeight: 26)
            .background(fill, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
