import Integration
import SwiftUI
import Subsonic

/// Song actions shared by "•••" menus and context menus.
struct SongMenuItems: View {
    @Environment(AppModel.self) private var model
    let song: Song
    /// False in Now Playing, where the song is already playing.
    var inQueue = true

    var body: some View {
        if inQueue {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext([song]) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue([song]) }
        }
        AddToPlaylistMenu(songs: [song])
        StationButton(seed: .song(song))
        Divider()
        Button("Get Info", systemImage: "info.circle") { model.infoSong = song }
        Button(model.isStarred(song) ? "Undo Favorite" : "Favorite", systemImage: model.isStarred(song) ? "star.slash" : "star") {
            model.toggleStar(song)
        }
        RatingMenu(song: song)
        SongDownloadMenuItem(song: song)
        Divider()
        Button("Go to Album", systemImage: "square.stack") { model.goToAlbum(song) }.disabled(song.albumId == nil)
        Button("Go to Artist", systemImage: "music.microphone") { model.goToArtist(song) }.disabled(song.artistId == nil)
        Divider()
        ShareMenuItems(target: ShareTarget(song: song))
        Button("Copy", systemImage: "doc.on.doc") { model.copy(song) }
    }
}

/// Plain song list with thin separators. `numbering` shows track numbers; `covers` shows small covers
/// and "artist — album". Double-click plays from the clicked row.
struct SongList: View {
    enum Leading { case track, cover }

    @Environment(AppModel.self) private var model
    let songs: [Song]
    var leading = Leading.track
    /// Hide the artist when it equals this (album pages).
    var albumArtist: String?
    let onPlay: (Int) -> Void
    /// Playlist pages: "Remove from Playlist" for the row at this index.
    var onRemove: ((Int) -> Void)?
    /// Playlist pages in playlist order: a row dropped on another moves there (from, to).
    var onMove: ((Int, Int) -> Void)?
    /// Index and id: the id stops a stale index from marking another song after the list changes.
    @State private var selected: (index: Int, id: String)?
    @State private var dropTarget: Int?

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                row(song, index)
                    .overlay(alignment: .bottom) {
                        if index < songs.count - 1 { Divider().padding(.leading, leading == .cover ? 64 : 50).padding(.trailing, 10) }
                    }
                    .overlay { if dropTarget == index { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.musicAccent, lineWidth: 2) } }
                    .draggable(DragPayload.songs([song.id], index: index).text)
                    .dropDestination(for: String.self) { items, _ in
                        guard let onMove, case .songs(_, let from?)? = items.first.flatMap(DragPayload.init) else { return false }
                        onMove(from, index)
                        return true
                    } isTargeted: { dropTarget = $0 && onMove != nil ? index : (dropTarget == index ? nil : dropTarget) }
            }
        }
    }

    private func row(_ song: Song, _ index: Int) -> some View {
        let isCurrent = model.player.current?.id == song.id
        return TrackRow(title: song.title, subtitle: subtitle(song), time: song.duration.map(TimeInterval.init),
                        isCurrent: isCurrent, isSelected: selected?.index == index && selected?.id == song.id,
                        isStarred: model.isStarred(song), badge: model.downloads.badge(song)) {
            switch leading {
            case .track:
                TrackNumber(text: song.track.map(String.init) ?? "", isCurrent: isCurrent)
            case .cover:
                CoverImage(id: song.coverArt, size: 100, cornerRadius: 4).frame(width: 40, height: 40)
            }
        } menu: {
            SongMenuItems(song: song)
            if let onRemove {
                Divider()
                Button("Remove from Playlist", systemImage: "minus.circle") { onRemove(index) }
            }
        }
        .opacity(model.downloads.isAvailable(song) ? 1 : 0.4)
        .onTapGesture(count: 2) { onPlay(index) }
        .simultaneousGesture(TapGesture().onEnded { selected = (index, song.id) })
    }

    private func subtitle(_ song: Song) -> String? {
        switch leading {
        case .cover: [song.artistName, song.album].compactMap { $0 }.joined(separator: " — ")
        case .track: song.artistName == albumArtist ? nil : song.artistName
        }
    }
}

/// "Get Info" sheet for a song.
struct SongInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                CoverImage(id: song.coverArt, size: 200).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.title3.bold())
                    Text([song.artistName, song.album].compactMap { $0 }.joined(separator: " — ")).foregroundStyle(.secondary)
                }
            }
            Form {
                if !model.ratingUnsupported {
                    LabeledContent("Rating") { RatingStars(rating: model.rating(song)) { model.setRating($0, for: song) } }
                }
                ForEach(fields, id: \.0) { LabeledContent($0.0, value: $0.1) }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Color.musicAccent)  // sheets do not get the window's tint
    }

    private var fields: [(String, String)] {
        [("Album Artist", song.albumArtist), ("Genre", song.genre), ("Year", song.year.map(String.init)),
         ("Track", song.track.map { "\($0)" + (song.discNumber.map { " · Disc \($0)" } ?? "") }),
         ("Duration", song.duration.map { formatTime(TimeInterval($0)) }), ("Format", song.sourceFormat),
         ("Size", song.size.map { formatBytes(Int64($0)) }), ("Plays", song.playCount.map(String.init)),
         ("Path", song.path)].compactMap { key, value in value.map { (key, $0) } }
    }
}
