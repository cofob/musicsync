import AppKit
import Subsonic
import Support
import SwiftUI

/// Mini player in the menu bar extra: the song, transport, volume and a peek at Up Next.
/// Only `ScrubBar` reads the elapsed time, so the rest does not redraw every tick.
struct MenuBarPlayer: View {
    /// Settings: show the menu bar item (default on) and the song title beside its icon (default off).
    static let shownKey = "menuBarItem"
    static let titleKey = "menuBarTitle"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            if let item = model.player.current {
                nowPlaying(item)
                UpNextPeek()
            } else {
                empty
            }
            Divider()
            HStack {
                Button("Open MusicSync") { showMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(HitAreaButtonStyle())
        }
        .padding(16)
        .frame(width: 300)
        .tint(Color.musicAccent)
    }

    private func nowPlaying(_ item: PlayItem) -> some View {
        let player = model.player
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                CoverFrame(image: player.artwork, cornerRadius: 6).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(player.errorMessage ?? item.artist ?? "").font(.subheadline).lineLimit(1)
                        .foregroundStyle(player.errorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if case .server(let song) = item {
                    let starred = model.isStarred(song)
                    Button(starred ? "Undo Favorite" : "Favorite", systemImage: starred ? "star.fill" : "star") { model.toggleStar(song) }
                        .labelStyle(.iconOnly).buttonStyle(HitAreaButtonStyle(width: 24, height: 24))
                        .foregroundStyle(starred ? AnyShapeStyle(Color.musicAccent) : AnyShapeStyle(.secondary))
                        .help(starred ? "Undo Favorite" : "Favorite")
                }
            }
            ScrubBar(timesBelow: true)
            TransportControls(scale: 1.1, spacing: 24)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                VolumeSlider()
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.tertiary).padding(.bottom, 4)
            Text("Not Playing").font(.headline)
            Text("Choose music in MusicSync.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
    }

    /// Brings back the main window, or opens a new one when it was closed.
    private func showMainWindow() {
        NSApp.activate()
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && ($0.isVisible || $0.isMiniaturized) }
        guard let window else { return openWindow(id: MainWindow.id) }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

/// The next few queue entries; a click plays one.
private struct UpNextPeek: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let upcoming = model.player.upcoming.prefix(5)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up Next").font(.subheadline.bold()).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(Array(upcoming.enumerated()), id: \.offset) { offset, item in
                    UpNextRow(item: item) { model.player.playUpcoming(at: offset) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UpNextRow: View {
    let item: PlayItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                CoverImage(id: item.coverArt, size: 100, cornerRadius: 4).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.callout).lineLimit(1)
                    Text(item.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(HitAreaButtonStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("Play")
    }
}

/// The menu bar icon: a template symbol that shows playing or paused, and optionally the song title.
struct MenuBarLabel: View {
    let player: Player
    @AppStorage(MenuBarPlayer.titleKey, store: .app) private var showsTitle = false

    var body: some View {
        Image(systemName: player.isPlaying ? "waveform" : "music.note")
        if showsTitle, let title = player.current?.title { Text(title.truncated(to: 24)) }
    }
}
