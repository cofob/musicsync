import SwiftUI
import Subsonic
import Support

enum NowPlayingPanel: String { case none, lyrics, queue }

/// Full-window player over a gradient sampled from the cover, with a lyrics or queue panel.
struct NowPlayingView: View {
    /// Room above the corner controls: none in a Mac window, the status bar on iPad.
    #if os(macOS)
    static let barInset: CGFloat = 0
    #else
    static let barInset: CGFloat = 24
    #endif

    @Environment(AppModel.self) private var model
    @State private var lyrics: Lyrics?
    /// False when the song has no lyrics: the player moves to the middle.
    @State private var showLyrics = false

    var body: some View {
        let player = model.player
        let song: Song? = if case .server(let s)? = player.current { s } else { nil }
        let panel = model.nowPlayingPanel == .lyrics && !showLyrics ? .none : model.nowPlayingPanel
        ZStack {
            if model.nowPlayingVisualizer {
                // The visualizer has the player itself: no cover, background or player column under it.
                // Its player keeps clear of the panel, else (centered) of the buttons in the bottom right corner.
                VisualizerView(inNowPlaying: true, showsOverlayLyrics: panel != .lyrics,
                               insets: panel != .none ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: Self.panelWidth)
                                                      : EdgeInsets(top: 0, leading: 150, bottom: 0, trailing: 150))
                    .transition(.opacity)
                // The panel stays usable over the visualizer: a dark column on the right.
                if panel != .none {
                    panelView(panel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 70 + Self.barInset).padding(.bottom, 70).padding(.horizontal, 24)
                        .frame(width: Self.panelWidth)
                        .background(.black.opacity(0.85))
                        .holdsVisualizerControls(model)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.opacity)
                }
            } else {
                let background = AppPreferences.shared.appearance.nowPlayingBackground
                if background == .visualizer {
                    // `.blur` does not reach the MilkDrop Metal view: a material over it blurs it.
                    VisualizerView(backdrop: true)
                        .overlay { Rectangle().fill(.ultraThinMaterial) }
                        .overlay(Color.black.opacity(0.55))
                        .overlay(Color.black.opacity(player.isPlaying ? 0 : 1))  // paused: plain black
                        .animation(.easeInOut(duration: 0.8), value: player.isPlaying)
                        .allowsHitTesting(false)
                } else {
                    ArtworkBackground(image: background == .plain ? nil : player.artwork, animated: background == .animated)
                }
                HStack(spacing: 40) {
                    PlayerColumn().frame(maxWidth: 440)
                        #if os(iOS)
                        .gesture(DragGesture(minimumDistance: 30).onEnded { drag in  // swipe down closes, as in iPad Music
                            if drag.translation.height > 120, abs(drag.translation.width) < drag.translation.height { model.showNowPlaying = false }
                        })
                        #endif
                    if panel != .none {
                        panelView(panel).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
                    }
                }
                .padding(.horizontal, 60).padding(.top, 70 + Self.barInset).padding(.bottom, 40)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Close", systemImage: "xmark") { model.showNowPlaying = false }
                .keyboardShortcut(.cancelAction)
                .labelStyle(.iconOnly).buttonStyle(HitAreaButtonStyle(width: 44, height: 32)).font(.system(size: 15, weight: .semibold))
                .glass(in: Capsule(), interactive: true)
                // The window buttons hide with the toolbar, so the close button takes their corner.
                .padding(.leading, 16).padding(.top, 12 + Self.barInset)
                .holdsVisualizerControls(model)
                .idleHidden(model.visualizerIdle)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                panelToggle("Lyrics", "quote.bubble", .lyrics)
                panelToggle("Queue", "list.bullet", .queue)
                Button("Visualizer", systemImage: "waveform") {
                    model.nowPlayingVisualizer.toggle()
                    if model.nowPlayingVisualizer { model.nowPlayingPanel = .none }  // its own lyrics show over it
                }
                    .labelStyle(.iconOnly).buttonStyle(HitAreaButtonStyle(width: 34, height: 30)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.nowPlayingVisualizer ? Color.black : .white)
                    .background(model.nowPlayingVisualizer ? Color.white.opacity(0.9) : .clear, in: Capsule())
                    .help("Visualizer")
                    .accessibilityValue(model.nowPlayingVisualizer ? "On" : "Off")
            }
            .padding(4).glass(in: Capsule())
            .holdsVisualizerControls(model)
            .padding(16)
            .idleHidden(model.visualizerIdle)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.smooth, value: model.nowPlayingPanel)
        .animation(.smooth, value: model.nowPlayingVisualizer)
        .task(id: song?.id) {
            // The panel stays while the next song's lyrics load; it goes away only when there are none.
            lyrics = nil
            let found = if let song { await model.lyrics(for: song) } else { Lyrics?.none }
            guard !Task.isCancelled else { return }
            lyrics = found
            withAnimation(.smooth(duration: 0.5)) { showLyrics = found != nil }
        }
    }

    /// Width of the Lyrics or Queue column over the visualizer.
    static let panelWidth: CGFloat = 440

    @ViewBuilder private func panelView(_ panel: NowPlayingPanel) -> some View {
        if panel == .lyrics { LyricsPanel(lyrics: lyrics) } else { UpNextPanel().padding(.trailing, 20).padding(.bottom, 50) }
    }

    private func panelToggle(_ title: String, _ symbol: String, _ panel: NowPlayingPanel) -> some View {
        let on = model.nowPlayingPanel == panel
        return Button(title, systemImage: symbol) { model.nowPlayingPanel = on ? .none : panel }
            .labelStyle(.iconOnly).buttonStyle(HitAreaButtonStyle(width: 34, height: 30)).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(on ? Color.black : .white)
            .background(on ? Color.white.opacity(0.9) : .clear, in: Capsule())
            .help(title)
            .accessibilityValue(on ? "On" : "Off")
    }
}

extension View {
    /// Gone while the visualizer has no mouse moves; the mouse then reaches the visualizer, which shows them again.
    func idleHidden(_ idle: Bool) -> some View {
        opacity(idle ? 0 : 1).allowsHitTesting(!idle).animation(.easeOut(duration: 0.3), value: idle)
    }

    /// The visualizer under this view does not see the mouse here: while it is here, the controls stay.
    func holdsVisualizerControls(_ model: AppModel) -> some View {
        onHover { model.visualizerHold = $0 }
    }
}

/// AirPlay and volume over the top right corner of Now Playing. `RootView` shows it beside Now Playing,
/// not inside it, so it fades and scales in and out on its own instead of sliding with the page.
struct NowPlayingVolume: View {
    @Environment(AppModel.self) private var model

    static let transition: AnyTransition = .opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)).combined(with: .offset(y: -6))

    var body: some View {
        HStack(spacing: 12) {
            if model.jukebox.isActive {
                PlayingOnServerLabel().font(.callout.weight(.semibold))
                Divider().frame(height: 18)
            }
            OutputButton(tint: .white).buttonStyle(HitAreaButtonStyle(width: 22, height: 22))
            AirPlayButton(tint: .white).frame(width: 22, height: 22)
            Divider().frame(height: 18)
            VolumeSlider(tint: .white).frame(width: 120)
            Image(systemName: volumeSymbol(model.player.volume)).frame(width: 22)
        }
        .padding(.horizontal, 14).frame(height: 36)
        .glass(in: Capsule())
        .background(WindowStill())
        .holdsVisualizerControls(model)  // on the capsule only: the frame below fills the window
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.trailing, 16).padding(.top, 10 + NowPlayingView.barInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .ignoresSafeArea()
    }
}

/// Cover, song info, progress and transport.
private struct PlayerColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            CoverFrame(image: player.artwork, cornerRadius: 12)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .frame(maxWidth: 440)
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "Not Playing").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(byline(player.current?.artist, player.current?.album))
                        .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.isMixing { AutoMixBadge() }
                if case .server(let song)? = player.current {
                    let starred = model.isStarred(song)
                    Button(starred ? "Undo Favorite" : "Favorite", systemImage: starred ? "star.fill" : "star") { model.toggleStar(song) }
                        .buttonStyle(RoundGlassStyle())
                        .accessibilityLabel("Favorite").accessibilityValue(starred ? "On" : "Off")
                    Menu { SongMenuItems(song: song, inQueue: false) } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.button).buttonStyle(RoundGlassStyle()).menuIndicator(.hidden).fixedSize()
                }
            }
            ScrubBar(height: 5, tint: .white, timesBelow: true)
            TransportControls(scale: 1.7, spacing: 50)
            Spacer(minLength: 0)
        }
    }
}

/// White-on-glass round button (star, "•••").
private struct RoundGlassStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly).font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 32)
            .animation(.press) { $0.background(.white.opacity(configuration.isPressed ? 0.3 : 0.15), in: Circle()) }
            .contentShape(Circle())
    }
}

/// Gradient made from the cover's colors (a 3×3 sample), with a soft dark veil for contrast.
struct ArtworkBackground: View {
    let image: NSImage?
    /// The colors drift slowly, as in Music; still with Reduce Motion.
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colors: [Color] = ArtworkBackground.fallback

    private static let fallback = Array(repeating: Color(white: 0.22), count: 9)

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { mesh(at: $0.date.timeIntervalSinceReferenceDate) }
            } else {
                mesh(at: 0)
            }
        }
        .overlay(Color.black.opacity(0.22))
        .ignoresSafeArea()
        .task(id: image.map(ObjectIdentifier.init)) {
            withAnimation(.easeInOut(duration: 0.8)) { colors = image.flatMap(Self.sample) ?? Self.fallback }
        }
    }

    /// The middle points circle slowly, edge points slide along their edge; at `time` 0 all rest
    /// where the still background has them.
    private func mesh(at time: TimeInterval) -> MeshGradient {
        func point(_ x: Float, _ y: Float, _ phase: Double, x dx: Float = 0.12, y dy: Float = 0.12) -> SIMD2<Float> {
            [x + dx * Float(sin(time / 7 + phase) - sin(phase)), y + dy * Float(cos(time / 9 + phase) - cos(phase))]
        }
        return MeshGradient(width: 3, height: 3, points: [
            [0, 0], point(0.5, 0, 1, y: 0), [1, 0],
            point(0, 0.5, 2, x: 0), point(0.55, 0.45, 3), point(1, 0.5, 4, x: 0),
            [0, 1], point(0.5, 1, 5, y: 0), [1, 1],
        ], colors: colors)
    }

    private static func sample(_ image: NSImage) -> [Color]? {
        coverSamples(image)?.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }
}

/// Lyrics of the current song; synced lines follow playback and seek on click.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil while loading.
    let lyrics: Lyrics?
    var size: CGFloat = 30

    var body: some View {
        if let lyrics { lines(lyrics) } else { ProgressView() }
    }

    private func lines(_ lyrics: Lyrics) -> some View {
        let current = currentLine(lyrics)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        let distance = current.map { abs($0 - i) } ?? 0
                        Text(line.text.isEmpty ? "• • •" : line.text)
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(.primary.opacity(!lyrics.isSynced || i == current ? 1 : 0.35))
                            .blur(radius: lyrics.isSynced ? min(Double(distance), 3) * 0.8 : 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { if let start = line.start { model.player.seek(to: start) } }
                            .id(i)
                    }
                    if let source = lyrics.source {
                        Text("Lyrics from \(source)").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                // Room for the blur on the left: the scroll view clips at its edge.
                .padding(.vertical, 220).padding(.leading, 16).padding(.trailing, 40)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: current)
            }
            .scrollIndicators(.never)
            .padding(.leading, -16)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                         .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            // The panel opens on the current line at once, then follows it smoothly.
            .onAppear { if let current { proxy.scrollTo(current, anchor: Self.anchor) } }
            .onChange(of: current) {
                guard let current else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { proxy.scrollTo(current, anchor: Self.anchor) }
            }
        }
    }

    private static let anchor = UnitPoint(x: 0, y: 0.35)

    private func currentLine(_ lyrics: Lyrics) -> Int? {
        guard lyrics.isSynced else { return nil }
        let t = model.player.elapsed + 0.25
        return lyrics.lines.lastIndex { ($0.start ?? .infinity) <= t }
    }
}
