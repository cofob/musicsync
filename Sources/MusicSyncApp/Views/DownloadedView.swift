import Library
import Subsonic
import SwiftUI

/// "Downloaded": music kept on this Mac. Running downloads, albums, playlists and every downloaded song.
/// A filter splits the user's own downloads from smart ones; smart songs show the rule that keeps them.
struct DownloadedView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", user = "Downloaded by You", smart = "Smart"
        var id: Self { self }
    }

    static let filterKey = "downloadedFilter"
    @Environment(AppModel.self) private var model
    @AppStorage(DownloadedView.filterKey, store: .app) private var filter = Filter.all
    @State private var confirmRemoveAll = false

    var body: some View {
        let downloads = model.downloads
        let all = downloads.entries.values.filter(shows)
        let songs = filter(all.filter { $0.state == .done }.map(\.song)).sorted(by: Self.libraryOrder)
        let pending = all.filter { $0.state != .done }.sorted { $0.song.title < $1.song.title }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(songs: all.count { $0.state == .done })
                if let block = downloads.status.blocked, !pending.isEmpty { BlockedNotice(block: block) }
                if !pending.isEmpty { ActiveDownloads(entries: pending) }
                if !albums.isEmpty, filter != .smart {
                    section("Albums") {
                        LazyVGrid(columns: albumGridColumns, spacing: 28) {
                            ForEach(albums) { AlbumCard(album: $0) }
                        }
                    }
                }
                if !playlists.isEmpty, filter != .smart {
                    section("Playlists") {
                        LazyVGrid(columns: albumGridColumns, spacing: 28) {
                            ForEach(playlists) { PlaylistCard(playlist: $0) }
                        }
                    }
                }
                if filter == .smart {
                    // One section per rule; a song kept by several rules is under the first.
                    ForEach(SmartRule.allCases, id: \.self) { rule in
                        let group = songs.filter { downloads.entries[$0.id]?.smartRules.first == rule }
                        if !group.isEmpty {
                            section(rule.title) {
                                SongList(songs: group, leading: .cover, onPlay: { model.player.play(group, startAt: $0) }, tag: tag)
                            }
                        }
                    }
                } else if !songs.isEmpty {
                    section("Songs") {
                        SongList(songs: songs, leading: .cover, onPlay: { model.player.play(songs, startAt: $0) }, tag: tag)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 32)
        }
        .overlay {
            if all.isEmpty && filter == .smart {
                ContentUnavailableView("No Smart Downloads", systemImage: "wand.and.sparkles",
                                       description: Text("Turn on smart downloads in Settings > Downloads to keep favorites and mixes offline."))
            } else if all.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download albums, playlists and songs to play them without a connection."))
            }
        }
        .navigationTitle("")
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll) {
            Button("Remove All", role: .destructive) { model.removeAllDownloads() }
        } message: {
            Text("\(formatBytes(downloads.usedBytes)) of music are deleted from this Mac. The songs stay in your library.")
        }
    }

    /// The controls go under the title when both do not fit on one line, so the title never breaks.
    private func header(songs: Int) -> some View {
        let title = VStack(alignment: .leading, spacing: 2) {
            Text("Downloaded").font(.system(size: 34, weight: .bold))
            Text("\(formatSongs(songs)) · \(formatBytes(model.downloads.usedBytes))").foregroundStyle(.secondary)
        }
        .lineLimit(1)
        let controls = HStack {
            if !model.downloads.entries.isEmpty {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Remove All…") { confirmRemoveAll = true }.buttonStyle(FilledCapsuleStyle())
            }
        }
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { title; Spacer(); controls }
            VStack(alignment: .leading, spacing: 14) { title; controls }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: title)
            content()
        }
    }

    private var albums: [Album] {
        model.downloads.pins.compactMap { if case .album(let a) = $0 { a } else { nil } }.filter { matches($0.name, $0.artistName) }
    }

    private var playlists: [Playlist] {
        model.downloads.pins.compactMap { if case .playlist(let p) = $0 { p } else { nil } }.filter { matches($0.name) }
    }

    private func shows(_ entry: DownloadEntry) -> Bool {
        switch filter {
        case .all: true
        case .user: entry.isUserKept
        case .smart: !entry.smartRules.isEmpty
        }
    }

    /// The rule that keeps a smart song, under "All" for songs the user does not keep too; "Smart" has a section per rule.
    private func tag(_ song: Song) -> String? {
        guard let entry = model.downloads.entries[song.id], filter == .all, !entry.isUserKept else { return nil }
        return entry.smartRules.first?.badge
    }

    /// "Find in Downloaded".
    private func filter(_ songs: [Song]) -> [Song] { songs.filter { matches($0.title, $0.artistName, $0.album) } }

    private func matches(_ fields: String?...) -> Bool {
        let query = model.query
        return query.isEmpty || fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// Artist, album, disc, track.
    private static func libraryOrder(_ a: Song, _ b: Song) -> Bool {
        let x = (a.artistName ?? "", a.album ?? "", a.discNumber ?? 1, a.track ?? 0)
        let y = (b.artistName ?? "", b.album ?? "", b.discNumber ?? 1, b.track ?? 0)
        if x.0 != y.0 { return x.0.localizedStandardCompare(y.0) == .orderedAscending }
        if x.1 != y.1 { return x.1.localizedStandardCompare(y.1) == .orderedAscending }
        return (x.2, x.3) < (y.2, y.3)
    }
}

/// Playlist grid cell, as on "All Playlists".
private struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        NavigationLink(value: Route.playlist(playlist)) {
            VStack(alignment: .leading, spacing: 2) {
                CoverImage(id: playlist.coverArt, size: 400, cornerRadius: 10, symbol: "music.note.list")
                    .overlay(alignment: .bottomTrailing) { DownloadBadge(reason: .playlist(playlist.id)).padding(6) }
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2).padding(.bottom, 6)
                Text(playlist.name).lineLimit(2)
                Text(formatSongs(model.downloads.groups[.playlist(playlist.id)]?.ids.count ?? 0)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .contextMenu {
            Button("Play", systemImage: "play.fill") { model.play(playlist) }
            PinMenuItem(reason: .playlist(playlist.id)) { model.download(playlist) }
        }
    }
}

/// Why queued songs do not start.
private struct BlockedNotice: View {
    let block: DownloadStatus.Block

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: block == .offline ? "wifi.slash" : "externaldrive.badge.exclamationmark")
                .font(.title3).foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if block == .storageLimit { SettingsLink { Text("Settings…") } }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var text: String {
        switch block {
        case .storageLimit: "Downloads are paused: the storage limit is reached. Raise it in Settings or remove downloads."
        case .diskFull: "Downloads are paused: the disk is almost full."
        case .offline: "Downloads continue when the server can be reached."
        }
    }
}

/// Queued, running and failed downloads, with cancel and retry.
private struct ActiveDownloads: View {
    @Environment(AppModel.self) private var model
    let entries: [DownloadEntry]

    var body: some View {
        let failed = entries.filter { $0.state == .failed }.map(\.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ShelfHeader(title: "Downloading")
                Text(formatSongs(entries.count)).foregroundStyle(.secondary)
                Spacer()
                if !failed.isEmpty {
                    Button("Retry All") { Task { await model.downloads.manager?.retry(failed) } }.buttonStyle(FilledCapsuleStyle())
                }
            }
            if model.downloads.status.batchTotal > 0 {
                ProgressView(value: model.downloads.status.fraction).tint(Color.musicAccent)
            }
            LazyVStack(spacing: 0) {
                ForEach(entries.prefix(50)) { row($0) }
            }
            if entries.count > 50 {
                Text("and \(formatSongs(entries.count - 50)) more").font(.callout).foregroundStyle(.secondary).padding(.leading, 10)
            }
        }
    }

    private func row(_ entry: DownloadEntry) -> some View {
        let manager = model.downloads.manager
        return HStack(spacing: 14) {
            CoverImage(id: entry.song.coverArt, size: 100, cornerRadius: 4).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.song.title).lineLimit(1)
                Text(detail(entry)).font(.callout).foregroundStyle(entry.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let progress = model.downloads.status.progress[entry.id] { DownloadRing(fraction: progress) }
            if entry.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise") { Task { await manager?.retry([entry.id]) } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(Color.musicAccent).help("Retry")
            } else {
                Button("Cancel", systemImage: "xmark.circle.fill") { Task { await manager?.cancel(entry.id) } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
            }
        }
        .padding(.horizontal, 10).frame(minHeight: 54)
    }

    private func detail(_ entry: DownloadEntry) -> String {
        switch entry.state {
        case .queued: return [entry.song.artistName, "Waiting"].compactMap { $0 }.joined(separator: " — ")
        case .downloading:
            let percent = Int((model.downloads.status.progress[entry.id] ?? 0) * 100)
            return [entry.song.artistName, "Downloading \(percent)%"].compactMap { $0 }.joined(separator: " — ")
        case .failed: return entry.isCancelled ? "Cancelled" : "Failed: \(entry.error ?? "unknown error")"
        case .done: return entry.song.artistName ?? ""
        }
    }
}
