import SwiftUI

/// Floating glass capsule at the bottom of the window: transport on the left, the song and its
/// progress in the middle, lyrics / queue / AirPlay / volume on the right.
struct PlayerCapsule: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 22) {
            TransportControls()
            center.frame(maxWidth: .infinity)
            HStack(spacing: 18) {
                panelButton("Lyrics", "quote.bubble", .lyrics)
                panelButton("Queue", "list.bullet", .queue)
                AirPlayButton().frame(width: 22, height: 22)
                VolumeButton()
            }
            .font(.system(size: 16))
            .buttonStyle(.plain).labelStyle(.iconOnly)
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
        .glass(in: Capsule())
    }

    @ViewBuilder private var center: some View {
        let player = model.player
        if let item = player.current {
            HStack(spacing: 12) {
                Button { model.showNowPlaying = true } label: {
                    HStack(spacing: 10) {
                        CoverFrame(image: player.artwork, cornerRadius: 5).frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(player.errorMessage ?? item.artist ?? "").font(.caption)
                                .foregroundStyle(player.errorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)).lineLimit(1)
                        }
                        .frame(maxWidth: 200, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Now Playing")
                ScrubBar().frame(maxWidth: 420)
            }
        } else {
            Image(systemName: "music.note").font(.title2).foregroundStyle(.tertiary)
        }
    }

    private func panelButton(_ title: String, _ symbol: String, _ panel: NowPlayingPanel) -> some View {
        Button(title, systemImage: symbol) {
            model.nowPlayingPanel = panel
            model.showNowPlaying = true
        }
        .help(title)
        .disabled(model.player.current == nil)
    }
}
