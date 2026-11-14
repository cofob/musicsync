import AppKit
import SwiftUI
import Subsonic

enum NowPlayingPanel: String { case none, lyrics, queue }

/// Full-window player over a gradient sampled from the cover, with a lyrics or queue panel.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @State private var lyrics: Lyrics?
    /// False when the song has no lyrics: the player moves to the middle.
    @State private var showLyrics = false

    var body: some View {
        let player = model.player
        let song: Song? = if case .server(let s)? = player.current { s } else { nil }
        let panel = model.nowPlayingPanel == .lyrics && !showLyrics ? .none : model.nowPlayingPanel
        ZStack {
            ArtworkBackground(image: AppPreferences.shared.appearance.nowPlayingBackground == .artwork ? player.artwork : nil)
            HStack(spacing: 40) {
                PlayerColumn().frame(maxWidth: 440)
                if panel != .none {
                    Group {
                        if panel == .lyrics { LyricsPanel(lyrics: lyrics) } else { UpNextPanel().padding(.trailing, 20).padding(.bottom, 50) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 60).padding(.top, 70).padding(.bottom, 40)
        }
        .overlay(alignment: .topLeading) {
            Button("Close", systemImage: "xmark") { model.showNowPlaying = false }
                .keyboardShortcut(.cancelAction)
                .labelStyle(.iconOnly).buttonStyle(HitAreaButtonStyle(width: 44, height: 32)).font(.system(size: 15, weight: .semibold))
                .glass(in: Capsule(), interactive: true)
                // The window buttons hide with the toolbar, so the close button takes their corner.
                .padding(.leading, 16).padding(.top, 12)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                panelToggle("Lyrics", "quote.bubble", .lyrics)
                panelToggle("Queue", "list.bullet", .queue)
            }
            .padding(4).glass(in: Capsule())
            .padding(16)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.smooth, value: model.nowPlayingPanel)
        .task(id: song?.id) {
            // The panel stays while the next song's lyrics load; it goes away only when there are none.
            lyrics = nil
            let found = if let song { await model.lyrics(for: song) } else { Lyrics?.none }
            guard !Task.isCancelled else { return }
            lyrics = found
            withAnimation(.smooth(duration: 0.5)) { showLyrics = found != nil }
        }
    }

    private func panelToggle(_ title: String, _ symbol: String, _ panel: NowPlayingPanel) -> some View {
        let on = model.nowPlayingPanel == panel
        return Button(title, systemImage: symbol) { model.nowPlayingPanel = on ? .none : panel }
            .labelStyle(.iconOnly).buttonStyle(HitAreaButtonStyle(width: 34, height: 30)).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(on ? Color.black : .white)
            .background(on ? Color.white.opacity(0.9) : .clear, in: Capsule())
            .help(title)
    }
}

/// AirPlay and volume over the top right corner of Now Playing. `RootView` shows it beside Now Playing,
/// not inside it, so it fades and scales in and out on its own instead of sliding with the page.
struct NowPlayingVolume: View {
    @Environment(AppModel.self) private var model

    static let transition: AnyTransition = .opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)).combined(with: .offset(y: -6))

    var body: some View {
        HStack(spacing: 12) {
            AirPlayButton(tint: .white).frame(width: 22, height: 22)
            Divider().frame(height: 18)
            VolumeSlider(tint: .white).frame(width: 120)
            Image(systemName: volumeSymbol(model.player.volume)).frame(width: 22)
        }
        .padding(.horizontal, 14).frame(height: 36)
        .glass(in: Capsule())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.trailing, 16).padding(.top, 10)
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
                    Text([player.current?.artist, player.current?.album].compactMap { $0 }.joined(separator: " — "))
                        .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if player.isMixing { AutoMixBadge() }
                if case .server(let song)? = player.current {
                    let starred = model.isStarred(song)
                    Button(starred ? "Undo Favorite" : "Favorite", systemImage: starred ? "star.fill" : "star") { model.toggleStar(song) }
                        .buttonStyle(RoundGlassStyle())
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
            .background(.white.opacity(configuration.isPressed ? 0.3 : 0.15), in: Circle())
            .contentShape(Circle())
    }
}

/// Gradient made from the cover's colors (a 3×3 sample), with a soft dark veil for contrast.
struct ArtworkBackground: View {
    let image: NSImage?
    @State private var colors: [Color] = ArtworkBackground.fallback

    private static let fallback = Array(repeating: Color(white: 0.22), count: 9)

    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.55, 0.45], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: colors)
        .overlay(Color.black.opacity(0.22))
        .ignoresSafeArea()
        .task(id: image.map(ObjectIdentifier.init)) {
            withAnimation(.easeInOut(duration: 0.8)) { colors = image.flatMap(Self.sample) ?? Self.fallback }
        }
    }

    /// Averages the image into a 3×3 grid of colors.
    private static func sample(_ image: NSImage) -> [Color]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 3, height: 3))
        let px = data.bindMemory(to: UInt8.self, capacity: 36)
        return (0..<9).map { i in
            Color(red: Double(px[4 * i]) / 255, green: Double(px[4 * i + 1]) / 255, blue: Double(px[4 * i + 2]) / 255)
        }
    }
}

/// Lyrics of the current song; synced lines follow playback and seek on click.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var model
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
                }
                // Room for the blur on the left: the scroll view clips at its edge.
                .padding(.vertical, 220).padding(.leading, 16).padding(.trailing, 40)
                .animation(.easeOut(duration: 0.35), value: current)
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
                withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(current, anchor: Self.anchor) }
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
