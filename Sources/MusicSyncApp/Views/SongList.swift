import Integration
import Preferences
import SwiftUI
import Subsonic
import Support

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
        NotForMeButton(song: song)
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
        SongFileMenus(songs: [song])
        Button("Copy", systemImage: "doc.on.doc") { model.copy(song) }
    }
}

/// Plain song list with thin separators. `numbering` shows track numbers; `covers` shows small covers
/// and "artist — album". Double-click plays from the clicked row. Click, ⌘-click, ⇧-click and ⌘A select rows;
/// the context menu, Return and Delete act on all of them.
struct SongList: View {
    enum Leading { case track, cover }
    /// A row: the song and how often it came before in the list, as a playlist may hold a song twice.
    struct RowKey: Hashable { let id: String, n: Int }

    @Environment(AppModel.self) private var model
    let songs: [Song]
    var leading = Leading.track
    /// Hide the artist when it equals this (album pages).
    var albumArtist: String?
    let onPlay: (Int) -> Void
    /// Playlist pages: "Remove from Playlist" and Delete for the rows at these indexes.
    var onRemove: (([Int]) -> Void)?
    /// Playlist pages in playlist order: a row dropped on another moves there (from, to).
    var onMove: ((Int, Int) -> Void)?
    /// Short label on a row (`TrackRow.tag`).
    var tag: ((Song) -> String?)?
    /// Row keys, not indexes: the selection stays on its songs after the list changes.
    @State private var selection = ListSelection<RowKey>()
    @State private var dropTarget: Int?
    /// The row an arrow key moved to, scrolled into view.
    @State private var moved: RowKey?
    @FocusState private var focused: Bool

    var body: some View {
        let keys = rowKeys
        let picked = selectedRows(keys)
        // The page's scroll view moves only as far as needed (anchor nil) to show the row an arrow key moved to.
        ScrollViewReader { proxy in
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    row(song, index, keys: keys, picked: picked).id(keys[index])
                        .overlay(alignment: .bottom) {
                            if index < songs.count - 1, !picked.contains(index), !picked.contains(index + 1) { Divider().padding(.leading, leading == .cover ? 64 : 50).padding(.trailing, 10) }
                        }
                        .overlay { if dropTarget == index { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.musicAccent, lineWidth: 2) } }
                        .draggable(dragPayload(index, picked).text)
                        .dropDestination(for: String.self) { items, _ in
                            guard let onMove, case .songs(_, let from?)? = items.first.flatMap(DragPayload.init) else { return false }
                            onMove(from, index)
                            return true
                        } isTargeted: { dropTarget = $0 && onMove != nil ? index : (dropTarget == index ? nil : dropTarget) }
                }
            }
            .onChange(of: moved) { proxy.scrollTo($1) }
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection.selectAll(keys) }
        // Key and command handlers read the selection now: at the root of the detail stack they can outlive a render.
        .onKeyPress(.return) { play(selectedRows(keys)) }
        .onDeleteCommand { remove(selectedRows(keys)) }
        .onKeyPress(.escape) { if selection.isEmpty { return .ignored }; selection.clear(); return .handled }
        .onKeyPress(.downArrow) { move(1, keys) }
        .onKeyPress(.upArrow) { move(-1, keys) }
        .focusedSceneValue(\.songListCommands, SongListCommands(selectAll: { selection.selectAll(keys); focused = true }, delete: { remove(selectedRows(keys)) }))
    }

    private func selectedRows(_ keys: [RowKey]) -> [Int] { keys.indices.filter { selection.contains(keys[$0]) } }

    private func move(_ offset: Int, _ keys: [RowKey]) -> KeyPress.Result {
        guard !keys.isEmpty else { return .ignored }
        selection.move(offset, in: keys)
        moved = selection.anchor
        return .handled
    }

    private func remove(_ rows: [Int]) {
        guard let onRemove, !rows.isEmpty else { return }
        onRemove(rows)
        selection.clear()
    }

    private func row(_ song: Song, _ index: Int, keys: [RowKey], picked: [Int]) -> some View {
        let isCurrent = model.player.current?.id == song.id
        let isSelected = selection.contains(keys[index])
        return TrackRow(title: song.title, subtitle: subtitle(song), time: song.duration.map(TimeInterval.init),
                        isCurrent: isCurrent, isSelected: isSelected, joined: isSelected ? joined(index, picked) : [],
                        isStarred: model.isStarred(song), badge: model.downloads.badge(song), detail: detail(song), tag: tag?(song)) {
            switch leading {
            case .track:
                TrackNumber(text: song.track.map(String.init) ?? "", isCurrent: isCurrent)
            case .cover:
                CoverImage(id: song.coverArt, size: 100, cornerRadius: 4).frame(width: 40, height: 40)
            }
        } menu: {
            let rows = isSelected && picked.count > 1 ? picked : [index]
            if rows.count > 1 { SongsMenuItems(songs: rows.map { songs[$0] }) } else { SongMenuItems(song: song) }
            if let onRemove {
                Divider()
                Button("Remove from Playlist", systemImage: "minus.circle") { onRemove(rows) }
            }
        }
        .opacity(model.downloads.isAvailable(song) ? 1 : 0.4)
        .onTapGesture(count: 2) { onPlay(index) }
        .simultaneousGesture(TapGesture().onEnded { select(keys[index], in: keys) })
    }

    private func joined(_ index: Int, _ picked: [Int]) -> VerticalEdge.Set {
        var edges: VerticalEdge.Set = []
        if picked.contains(index - 1) { edges.insert(.top) }
        if picked.contains(index + 1) { edges.insert(.bottom) }
        return edges
    }

    private var rowKeys: [RowKey] {
        var seen: [String: Int] = [:]
        return songs.map { song in
            let n = seen[song.id, default: 0]
            seen[song.id] = n + 1
            return RowKey(id: song.id, n: n)
        }
    }

    private func select(_ key: RowKey, in keys: [RowKey]) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) { selection.extend(to: key, in: keys) }
        else if flags.contains(.command) { selection.toggle(key) }
        else { selection.click(key) }
        focused = true
    }

    /// One row plays the list from there, as a double-click does; several play alone.
    private func play(_ rows: [Int]) -> KeyPress.Result {
        guard let first = rows.first else { return .ignored }
        if rows.count == 1 { onPlay(first) } else { model.player.play(rows.map { songs[$0] }) }
        return .handled
    }

    /// A selected row drags the whole selection (onto a sidebar playlist); a lone row keeps its index for reordering.
    private func dragPayload(_ index: Int, _ picked: [Int]) -> DragPayload {
        picked.count > 1 && picked.contains(index) ? .songs(picked.map { songs[$0].id }, index: nil) : .songs([songs[index].id], index: index)
    }

    private func detail(_ song: Song) -> String? {
        AppearanceSettings.SongColumn.detail(AppPreferences.shared.appearance.songColumns, rating: model.rating(song),
                                             plays: song.playCount, suffix: song.suffix, bitRate: song.bitRate)
    }

    private func subtitle(_ song: Song) -> String? {
        switch leading {
        case .cover: byline(song.artistName, song.album)
        case .track: song.artistName == albumArtist ? nil : song.artistName
        }
    }
}

/// Select All and Delete of the page's `SongList`, for `RootView`: on the root page of the detail stack the
/// menu commands go to the window's hosting view, which does not see the list's own command handlers.
struct SongListCommands {
    let selectAll: () -> Void
    let delete: () -> Void
}

extension FocusedValues {
    @Entry var songListCommands: SongListCommands?
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
                    Text(byline(song.artistName, song.album)).foregroundStyle(.secondary)
                }
            }
            Form {
                if !model.ratingUnsupported {
                    LabeledContent("Rating") { RatingStars(rating: model.rating(song)) { model.setRating($0, for: song) } }
                }
                ForEach(fields, id: \.0) { LabeledContent($0.0, value: $0.1) }
                if model.player.current?.id == song.id, let quality = model.player.activeQuality {
                    LabeledContent("Playing As", value: quality + (model.player.isMetered ? " · Metered network" : ""))
                }
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
