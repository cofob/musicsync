import SwiftUI
import Subsonic

/// Every song of the library in a sortable table. Double-click plays the visible rows from the clicked one.
struct SongsView: View {
    struct Row: Identifiable {
        let song: Song
        var id: String { song.id }
        var title: String { song.title }
        var duration: Int { song.duration ?? 0 }
        var artist: String { song.artistName ?? "" }
        var album: String { song.album ?? "" }
        var genre: String { song.genre ?? "" }
        var plays: Int { song.playCount ?? 0 }
        var starred: Int { song.starred == nil ? 0 : 1 }
    }

    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\Row.artist, comparator: .localizedStandard)]
    @State private var rows: [Row] = []
    @State private var selection = Set<Row.ID>()

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title, comparator: .localizedStandard) { row in
                // Accent marks would be red on the blue selection; selected rows use the table's own colors.
                let selected = selection.contains(row.id)
                HStack {
                    Text(row.title).lineLimit(1)
                        .foregroundStyle(model.player.current?.id == row.id && !selected ? Color.musicAccent : .primary)
                    Spacer(minLength: 4)
                    RowMenu(tint: selected ? .primary : .musicAccent) { SongMenuItems(song: row.song) }
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Time", value: \.duration) { Text(formatTime(TimeInterval($0.duration))).monospacedDigit() }
                .width(min: 44, ideal: 52, max: 70)
            TableColumn("Artist", value: \.artist, comparator: .localizedStandard) { Text($0.artist).lineLimit(1) }
                .width(min: 100, ideal: 180)
            TableColumn("Album", value: \.album, comparator: .localizedStandard) { Text($0.album).lineLimit(1) }
                .width(min: 100, ideal: 200)
            TableColumn("Genre", value: \.genre, comparator: .localizedStandard) { Text($0.genre).lineLimit(1) }
                .width(min: 60, ideal: 110)
            TableColumn("\u{2606}", value: \.starred) { row in
                if model.isStarred(row.song) {
                    Image(systemName: "star.fill").foregroundStyle(selection.contains(row.id) ? Color.primary : .musicAccent)
                }
            }
            .width(min: 24, ideal: 28, max: 36)
            TableColumn("Plays", value: \.plays) { Text($0.plays > 0 ? String($0.plays) : "").monospacedDigit() }
                .width(min: 40, ideal: 50, max: 70)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if ids.count == 1, let row = rows.first(where: { ids.contains($0.id) }) { SongMenuItems(song: row.song) }
        } primaryAction: { ids in
            if let id = ids.first { play(id) }
        }
        .overlay {
            if rows.isEmpty {
                if let error = model.songsError { LoadFailedView(message: error) { Task { await model.loadSongs() } } }
                else if !model.songsLoaded { songsPlaceholder }
                else if !model.searchText.isEmpty { ContentUnavailableView.search(text: model.searchText) }
                else { ContentUnavailableView("No Songs", systemImage: "music.note") }
            }
        }
        .navigationTitle("Songs")
        .toolbar {
            ToolbarItem { if !model.songsLoaded && !rows.isEmpty { ProgressView().controlSize(.small) } }
        }
        .task(id: model.libraryVersion) { await model.loadSongs() }
        .onChange(of: model.songs.count, initial: true) { rebuild() }
        .onChange(of: model.searchText) { rebuild() }
        .onChange(of: sortOrder) { rebuild() }
    }

    /// Gray lines under the table header while the first page loads.
    private var songsPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { i in
                HStack(spacing: 24) {
                    PlaceholderBlock(width: CGFloat(120 + (i * 41) % 110), height: 10)
                    Spacer()
                    PlaceholderBlock(width: 30, height: 10)
                    PlaceholderBlock(width: 110, height: 10)
                    PlaceholderBlock(width: 130, height: 10)
                    PlaceholderBlock(width: 60, height: 10)
                    Spacer().frame(width: 60)
                }
                .frame(height: 24).padding(.horizontal, 16)
            }
            Spacer()
        }
        .padding(.top, 30)
        .shimmering()
        .allowsHitTesting(false)
    }

    private func rebuild() {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let all = model.songs.map(Row.init)
        let matching = query.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
        rows = matching.sorted(using: sortOrder)
    }

    /// Queues the visible rows, starting at `id`.
    private func play(_ id: Row.ID) {
        model.player.play(rows.map(\.song), startAt: rows.firstIndex { $0.id == id } ?? 0)
    }
}
