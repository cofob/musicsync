import AppKit
import SwiftUI
import Subsonic

/// MiniPlayer: a small window filled by the cover, with the song and controls on hover and
/// Up Next below on demand. Opening it hides the main window; closing it brings the main window back.
enum MiniPlayer {
    static let id = "mini-player"
    static let onTopKey = "miniPlayerOnTop"
    static let queueKey = "miniPlayerQueue"
    static let visualizerKey = "miniPlayerVisualizer"
    /// Height Up Next adds below the cover.
    static let queueHeight: CGFloat = 340
    /// The main window hidden by `open`, shown again when the MiniPlayer closes.
    @MainActor private static weak var hiddenMain: NSWindow?

    @MainActor static func open(_ openWindow: OpenWindowAction) {
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && $0.isVisible }) {
            hiddenMain = main
            main.orderOut(nil)
        }
        openWindow(id: id)
    }

    @MainActor static func closed() {
        hiddenMain?.makeKeyAndOrderFront(nil)
        hiddenMain = nil
    }
}

/// Window menu items: "Switch to MiniPlayer" (⌥⌘M) and "Keep MiniPlayer on Top".
struct MiniPlayerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MiniPlayer.onTopKey, store: .app) private var onTop = false

    var body: some Commands {
        CommandGroup(after: .windowSize) {
            Button("Switch to MiniPlayer") { MiniPlayer.open(openWindow) }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Toggle("Keep MiniPlayer on Top", isOn: $onTop)
        }
    }
}

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(MiniPlayer.onTopKey, store: .app) private var onTop = false
    @AppStorage(MiniPlayer.queueKey, store: .app) private var showsQueue = false
    @AppStorage(MiniPlayer.visualizerKey, store: .app) private var showsVisualizer = false
    @State private var hovering = false
    /// The controls show for a moment when the window opens, so the user sees them.
    @State private var peek = true
    @State private var window: NSWindow?
    @State private var resize: Task<Void, Never>?

    var body: some View {
        let player = model.player
        VStack(spacing: 0) {
            CoverFrame(image: player.artwork, cornerRadius: 0)
                .overlay { if showsVisualizer { VisualizerView(compact: true) } }
                .overlay { if hovering || peek || player.current == nil { controls.transition(.opacity) } }
                .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
            if showsQueue {
                UpNextPanel().padding(.leading, 16).padding(.trailing, 4).padding(.top, 10)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ArtworkBackground(image: player.artwork) }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .background(WindowReader { window = $0; fit(animate: false) })
        .onChange(of: onTop, initial: true) { window?.level = onTop ? .floating : .normal }
        .onChange(of: showsQueue) { fit(animate: true) }
        .onDisappear { MiniPlayer.closed() }
        .task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.3)) { peek = false }
        }
    }

    /// Song, scrubber and buttons over a dark gradient.
    private var controls: some View {
        let player = model.player
        let song: Song? = if case .server(let s)? = player.current { s } else { nil }
        return VStack(spacing: 8) {
            HStack {
                Spacer()
                Button("Show Main Window", systemImage: "arrow.up.left.and.arrow.down.right") { dismissWindow(id: MiniPlayer.id) }
                    .help("Show Main Window")
            }
            Spacer()
            if let item = player.current {
                VStack(spacing: 1) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                ScrubBar(tint: .white)
            }
            HStack(spacing: 8) {
                Button(song.map(model.isStarred) == true ? "Undo Favorite" : "Favorite",
                       systemImage: song.map(model.isStarred) == true ? "star.fill" : "star") { song.map(model.toggleStar) }
                    .disabled(song == nil)
                    .accessibilityLabel("Favorite").accessibilityValue(song.map(model.isStarred) == true ? "On" : "Off")
                Spacer(minLength: 0)
                TransportControls(scale: 0.85, spacing: 10)
                Spacer(minLength: 0)
                AirPlayButton(tint: .white).frame(width: 20, height: 20)
                Button("Visualizer", systemImage: "waveform") { showsVisualizer.toggle() }
                    .foregroundStyle(showsVisualizer ? Color.musicAccent : .white)
                    .help("Visualizer")
                    .accessibilityValue(showsVisualizer ? "On" : "Off")
                Button("Up Next", systemImage: "list.bullet") { showsQueue.toggle() }
                    .foregroundStyle(showsQueue ? Color.musicAccent : .white)
                    .help("Up Next")
                    .accessibilityValue(showsQueue ? "On" : "Off")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(HitAreaButtonStyle(width: 24, height: 24))
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        .background(LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.1), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    /// The window keeps the square cover; Up Next adds height below it, the top edge stays. The animation steps
    /// the frame from a task: `setFrame(_:display:animate:)` blocks the app while it runs, and the window animator
    /// leaves the Up Next table in a live resize that crashes when the table goes.
    private func fit(animate: Bool) {
        guard let window else { return }
        let top = window.frame.maxY, from = window.frame.height
        let to = window.frame.width + (showsQueue ? MiniPlayer.queueHeight : 0)
        resize?.cancel()
        resize = Task {
            for step in animate ? 1...12 : 12...12 {
                if animate { try? await Task.sleep(for: .milliseconds(16)) }
                guard !Task.isCancelled else { return }
                let t = Double(step) / 12, height = from + (to - from) * t * (2 - t)  // ease out
                window.setFrame(NSRect(x: window.frame.minX, y: top - height, width: window.frame.width, height: height), display: true)
            }
        }
        if showsQueue { window.contentResizeIncrements = NSSize(width: 1, height: 1) }
        else { window.contentAspectRatio = NSSize(width: 1, height: 1) }
        window.isMovableByWindowBackground = true
        window.level = onTop ? .floating : .normal
    }
}

/// Hands over the window the view is in, once it has one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Reader: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// Later, not inside the layout pass that moves the view: resizing the window there breaks the Up Next list.
        override func viewDidMoveToWindow() {
            guard let window else { return }
            Task { @MainActor in onWindow(window) }
        }
    }
}
