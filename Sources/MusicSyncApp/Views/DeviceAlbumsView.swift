import SwiftUI

/// iPod cover from the ArtworkDB.
struct DeviceCoverImage: View {
    @Environment(AppModel.self) private var model
    let imageID: UInt32?
    var cornerRadius: CGFloat = 8
    var symbol = "music.note"
    @State private var image: NSImage?

    var body: some View {
        CoverFrame(image: image, cornerRadius: cornerRadius, symbol: symbol)
            .task(id: imageID) {
                image = nil
                guard let imageID, let artwork = model.ipod.snapshot?.artwork else { return }
                image = await artwork.image(id: imageID)
            }
    }
}

/// Grid cell: big rounded cover, bold title, secondary subtitle.
struct DeviceCard: View {
    let route: Route
    let imageID: UInt32?
    var symbol = "music.note"
    let title: String
    let subtitle: String
    let onPlay: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 4) {
                DeviceCoverImage(imageID: imageID, symbol: symbol)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .padding(.bottom, 4)
                Text(title).font(.callout.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: onPlay)
            if let onDelete { Divider(); DeleteFromIPodButton(action: onDelete) }
        }
    }
}

/// iPod albums grid; cards come in pages as they scroll in (`PagedList`), as on the library Albums page.
struct DeviceAlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var list: PagedList<DeviceAlbum>?

    var body: some View {
        Group {
            if model.ipod.snapshot == nil || list == nil {
                ProgressView()
            } else if let list, list.count == 0 {
                ContentUnavailableView("No Albums", systemImage: "square.stack",
                                       description: Text(model.query.isEmpty ? "There is no music on this iPod." : "No matches."))
            } else if let list {
                ScrollView {
                    LazyVGrid(columns: albumGridColumns, spacing: 24) {
                        ForEach(0..<list.count, id: \.self) { i in
                            PagedRow(list: list, index: i) { album in
                                DeviceCard(route: .deviceAlbum(album.id), imageID: album.imageID, title: album.name.nilIfEmpty ?? "Unknown Album",
                                           subtitle: album.artist.nilIfEmpty ?? "Unknown Artist", onPlay: { model.play(album.tracks) },
                                           onDelete: { model.sync.tracksToDelete = album.tracks })
                            } placeholder: { PlaceholderCard() }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Albums")
        .task(id: [String(model.ipod.version), model.searchText]) {
            if list != nil { try? await Task.sleep(for: .milliseconds(150)) }  // typing
            guard !Task.isCancelled else { return }
            let query = model.query
            let all = model.ipod.snapshot?.albums ?? []
            let found = await AppModel.slices(query.isEmpty ? all : all.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
            })
            if !Task.isCancelled { list = found }
        }
    }
}

struct DeviceAlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        if let album = model.ipod.snapshot?.albums.first(where: { $0.id == id }) {
            ScrollView {
                MediaHeader(cover: { DeviceCoverImage(imageID: album.imageID, cornerRadius: 10) },
                            title: album.name.nilIfEmpty ?? "Unknown Album", canPlay: !album.tracks.isEmpty,
                            onPlay: { model.play(album.tracks) }, onShuffle: { model.play(album.tracks, shuffled: true) }) {
                    Text(album.artist.nilIfEmpty ?? "Unknown Artist").font(.title3.weight(.semibold)).foregroundStyle(Color.musicAccent)
                    Text([album.year.map(String.init), formatSongs(album.tracks.count), formatTotal(Int(album.duration))]
                        .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                DeviceTrackList(tracks: album.tracks, leading: .number)
            }
            .navigationTitle(album.name)
        } else {
            ContentUnavailableView("Album Not Found", systemImage: "square.stack")
        }
    }
}

/// Plain song list with thin separators, a time and a "•••" menu per row. Double-click plays.
struct DeviceTrackList: View {
    enum Leading { case number, position, cover }

    @Environment(AppModel.self) private var model
    let tracks: [DeviceTrack]
    let leading: Leading
    /// Index and id: the id stops a stale index from marking another track after the list changes.
    @State private var selected: (index: Int, id: UInt32)?

    var body: some View {
        LazyVStack(spacing: 0) {
            Divider()
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                row(track, index)
                Divider().padding(.leading, 70)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
    }

    private func row(_ track: DeviceTrack, _ index: Int) -> some View {
        HStack(spacing: 12) {
            leadingView(track, index).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(subtitle(track)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(formatTime(track.duration)).monospacedDigit().foregroundStyle(.secondary)
            RowMenu { menu(track, index) }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(selected?.index == index && selected?.id == track.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(index) }
        .onTapGesture { selected = (index, track.id) }
        .contextMenu { menu(track, index) }
    }

    @ViewBuilder private func menu(_ track: DeviceTrack, _ index: Int) -> some View {
        Button("Play", systemImage: "play.fill") { play(index) }
        Divider()
        DeleteFromIPodButton { model.sync.tracksToDelete = [track] }
    }

    @ViewBuilder private func leadingView(_ track: DeviceTrack, _ index: Int) -> some View {
        switch leading {
        case .number:
            Text(track.trackNumber > 0 ? String(track.trackNumber) : "").monospacedDigit().foregroundStyle(.secondary)
        case .position:
            Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
        case .cover:
            DeviceCoverImage(imageID: track.imageID, cornerRadius: 4).frame(width: 44, height: 44)
        }
    }

    private func subtitle(_ track: DeviceTrack) -> String {
        let plays = track.plays > 0 ? "\(track.plays) \(track.plays == 1 ? "play" : "plays")" : nil
        return [leading == .number ? nil : track.artist.nilIfEmpty, track.album.nilIfEmpty.flatMap { leading == .number ? nil : $0 },
                track.format.nilIfEmpty, plays].compactMap { $0 }.joined(separator: " · ")
    }

    private func play(_ index: Int) { model.play(tracks, startAt: index) }
}

/// Asks to delete songs from the iPod (see `SyncModel.tracksToDelete`). Off while a sync runs.
struct DeleteFromIPodButton: View {
    @Environment(AppModel.self) private var model
    let action: () -> Void

    var body: some View {
        Button("Delete from iPod…", systemImage: "trash", role: .destructive, action: action)
            .disabled(model.sync.isRunning || model.client == nil || model.ipod.current == nil)
    }
}
