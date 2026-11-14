import Support
import SwiftUI

/// Floating glass capsule at the bottom of the window, as in Apple Music: small transport on the left, the song
/// with its progress under it in the middle, the song menu, lyrics / queue / AirPlay / volume on the right.
struct PlayerCapsule: View {
    @Environment(AppModel.self) private var model
    /// A narrow capsule (a small window) leaves out shuffle, repeat and "•••" to keep room for the song.
    @State private var compact = false

    var body: some View {
        HStack(spacing: 20) {
            TransportControls(scale: 0.78, spacing: 12, compact: compact)
            center.frame(maxWidth: .infinity)
            HStack(spacing: 18) {
                if !compact { songMenu }
                VolumeButton {
                    panelButton("Lyrics", "quote.bubble", .lyrics)
                    panelButton("Queue", "list.bullet", .queue)
                    OutputButton()
                    AirPlayButton().frame(width: 20, height: 20)
                }
            }
            .font(.system(size: 15))
            .buttonStyle(HitAreaButtonStyle(width: 22, height: 22)).labelStyle(.iconOnly)
        }
        .padding(.leading, 20).padding(.trailing, 12)
        .frame(height: 54)
        .glass(in: Capsule())
        // No minimum width from the content: one that changed with `compact` would make the window lay out forever.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: Bool.self) { $0.size.width < 640 } action: { compact = $0 }
    }

    @ViewBuilder private var center: some View {
        let player = model.player
        if let item = player.current {
            VStack(spacing: 3) {
                Button { model.showNowPlaying = true } label: {
                    HStack(spacing: 10) {
                        CoverFrame(image: player.artwork, cornerRadius: 4).frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Marquee(text: item.title).font(.callout.weight(.semibold))
                            if let error = player.errorMessage {
                                Text(error).font(.callout).foregroundStyle(.red).lineLimit(1)
                            } else if model.jukebox.isActive {
                                PlayingOnServerLabel().font(.callout).foregroundStyle(Color.musicAccent)
                            } else {
                                Marquee(text: byline(item.artist, item.album))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HitAreaButtonStyle())
                .help("Open Now Playing")
                SeekBar()
            }
            .padding(.top, 5)
        } else {
            Image(systemName: "music.note").font(.title2).foregroundStyle(.tertiary)
        }
    }

    /// The "•••" menu of the current song; kept as a gap for other items so the icons do not move.
    @ViewBuilder private var songMenu: some View {
        if case .server(let song)? = model.player.current {
            Menu { SongMenuItems(song: song, inQueue: false) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                .tint(.primary).help("More")
        } else {
            Color.clear.frame(width: 22, height: 22)
        }
    }

    private func panelButton(_ title: String, _ symbol: String, _ value: NowPlayingPanel) -> some View {
        Button(title, systemImage: symbol) {
            model.nowPlayingPanel = value
            model.showNowPlaying = true
        }
        .help(title)
        .disabled(model.player.current == nil)
    }
}

/// Thin progress bar under the song; the times show beside it while the pointer is over it.
private struct SeekBar: View {
    @State private var hovering = Shot.scene == "seek-hover"

    var body: some View {
        ScrubBar(height: 3, showsTimes: hovering)
            .frame(height: 8)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
