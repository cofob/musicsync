import SwiftUI
import Subsonic

/// Lyrics or the queue in a column at the right of the main window, as in Apple Music. The bottom capsule
/// and the View menu toggle it; the choice is kept across launches.
struct SidePanel: View {
    static let key = "sidePanel"
    @AppStorage(SidePanel.key, store: .app) private var panel = NowPlayingPanel.none

    var body: some View {
        Group {
            if panel == .lyrics { SideLyrics() } else { UpNextPanel() }
        }
        .padding(.horizontal, 12).padding(.top, 8)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
}

/// Lyrics of the current song in the side panel.
private struct SideLyrics: View {
    @Environment(AppModel.self) private var model
    @State private var lyrics: Lyrics?
    @State private var loaded = false

    var body: some View {
        let song: Song? = if case .server(let s)? = model.player.current { s } else { nil }
        Group {
            if lyrics != nil || !loaded {
                LyricsPanel(lyrics: lyrics, size: 20)
            } else {
                ContentUnavailableView("No Lyrics", systemImage: "quote.bubble")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: song?.id) {
            loaded = false
            let found = if let song { await model.lyrics(for: song) } else { Lyrics?.none }
            guard !Task.isCancelled else { return }
            lyrics = found
            loaded = true
        }
    }
}

/// View menu items that toggle the side panel.
struct SidePanelMenuItems: View {
    @AppStorage(SidePanel.key, store: .app) private var panel = NowPlayingPanel.none

    var body: some View {
        toggle("Lyrics", .lyrics).keyboardShortcut("l", modifiers: [.command, .option])
        toggle("Playing Next", .queue).keyboardShortcut("u", modifiers: [.command, .option])
    }

    private func toggle(_ title: String, _ value: NowPlayingPanel) -> some View {
        Toggle(title, isOn: Binding(get: { panel == value }, set: { panel = $0 ? value : .none }))
    }
}
