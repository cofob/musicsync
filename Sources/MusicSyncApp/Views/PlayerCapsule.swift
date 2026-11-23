import Support
import SwiftUI

/// Floating glass capsule at the bottom of the window: small transport on the left, the song
/// with its progress under it in the middle, the song menu, lyrics / queue / AirPlay / volume on the right.
struct PlayerCapsule: View {
    #if os(macOS)
    private static let (height, iconSize, hitSize, transportScale): (CGFloat, CGFloat, CGFloat, CGFloat) = (54, 15, 22, 0.78)
    #else  // sized for a finger
    private static let (height, iconSize, hitSize, transportScale): (CGFloat, CGFloat, CGFloat, CGFloat) = (66, 19, 40, 1)
    #endif
    @Environment(AppModel.self) private var model
    /// A narrow capsule (a small window) leaves out shuffle, repeat and "•••" to keep room for the song.
    @State private var compact = false

    var body: some View {
        HStack(spacing: 20) {
            TransportControls(scale: Self.transportScale, spacing: 12, compact: compact)
            center.frame(maxWidth: .infinity)
            HStack(spacing: 18) {
                if !compact { songMenu }
                VolumeButton {
                    panelButton("Lyrics", "quote.bubble", .lyrics)
                    panelButton("Queue", "list.bullet", .queue)
                    OutputButton()
                    AirPlayButton().frame(width: Self.iconSize + 5, height: Self.iconSize + 5)
                }
            }
            .font(.system(size: Self.iconSize))
            .buttonStyle(HitAreaButtonStyle(width: Self.hitSize, height: Self.hitSize)).labelStyle(.iconOnly)
        }
        .padding(.leading, 20).padding(.trailing, 12)
        .frame(height: Self.height)
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
            Menu {
                SongMenuItems(song: song, inQueue: false)
                #if os(iOS)  // the Mac has these in the Playback menu
                Divider()
                Menu("Playback", systemImage: "play.circle") { PlaybackMenuItems() }
                #endif
            } label: { Image(systemName: "ellipsis") }
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

#if os(iOS)
/// AutoPlay, Private Session, the sleep timer and the equalizer, for iPad without a keyboard.
private struct PlaybackMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Toggle("AutoPlay", isOn: Binding(get: { model.mixes.autoPlay }, set: { model.mixes.autoPlay = $0 }))
            .disabled(!model.mixes.isAvailable)
        Toggle("Private Session", isOn: Binding(get: { model.player.privateSession }, set: { model.player.privateSession = $0 }))
        SleepTimerPicker(selection: Binding(get: { model.player.sleepTimer }, set: { model.player.sleepTimer = $0 }))
        EqualizerMenuItem()
    }
}
#endif

/// Thin progress bar under the song; the times show beside it while the pointer is over it.
private struct SeekBar: View {
    @State private var hovering = Shot.scene == "seek-hover"

    var body: some View {
        ScrubBar(height: 3, showsTimes: hovering || isTouchUI)
            .frame(height: 8)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
