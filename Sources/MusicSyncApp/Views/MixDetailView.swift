import Recommend
import SwiftUI

/// A "Made for You" mix or a "Because You Listened to" station: its songs, Play / Shuffle and Save as Playlist.
struct MixDetailView: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let mixes = model.mixes
        if let mix = mixes.mix(id: id) {
            let songs = mixes.songs(of: mix)
            ScrollView {
                MediaHeader(cover: { MixArtwork(mix: mix, songs: songs) },
                            title: mix.kind == .because ? "Because You Listened to \(mix.title)" : mix.title, canPlay: !songs.isEmpty,
                            onPlay: { mixes.play(mix, shuffled: false) }, onShuffle: { mixes.play(mix, shuffled: true) }) {
                    Text(mix.subtitle).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.musicAccent).lineLimit(2)
                    Text("\(formatSongs(songs.count)), \(formatTotal(songs.reduce(0) { $0 + ($1.duration ?? 0) }))")
                        .font(.callout).foregroundStyle(.secondary)
                    if !mix.reason.isEmpty { Text(mix.reason).font(.callout).foregroundStyle(.secondary) }
                } accessory: {
                    Button("Save as Playlist", systemImage: "text.badge.plus") { mixes.save(mix) }
                        .buttonStyle(CircleIconStyle()).help("Save as Playlist")
                }
                VStack(spacing: 0) {
                    TrackListHeader()
                    SongList(songs: songs, leading: .cover) { mixes.play(mix, startAt: $0) }
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
            .navigationTitle(mix.title)
        } else {
            ContentUnavailableView("Mix Not Available", systemImage: "music.note.list",
                                   description: Text("Mixes are made from the local library once it is downloaded."))
        }
    }
}
