import Library
import SwiftUI
import Subsonic

/// Every song of the library in a sortable table. Rows come in pages as they scroll in (`PagedList`);
/// the database sorts and filters. Double-click plays from the clicked row.
struct SongsView: View {
    /// Row `index`. The properties only name the sortable columns: the database sorts, the table never does.
    struct Row: Identifiable {
        let id: Int
        var title: String { "" }
        var duration: Int { 0 }
        var artist: String { "" }
        var album: String { "" }
        var plays: Int { 0 }
    }

    struct Rows: RandomAccessCollection {
        let endIndex: Int
        var startIndex: Int { 0 }
        subscript(index: Int) -> Row { Row(id: index) }
    }

    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\Row.artist, comparator: .localizedStandard)]
    @State private var list: PagedList<Song>?
    @State private var selection = Set<Row.ID>()

    var body: some View {
        Table(Rows(endIndex: list?.count ?? 0), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title, comparator: .localizedStandard) { row in
                if let song = song(row) { titleCell(row, song) }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Time", value: \.duration) { Text(song($0).flatMap(\.duration).map { formatTime(TimeInterval($0)) } ?? "").monospacedDigit() }
                .width(min: 44, ideal: 52, max: 70)
            TableColumn("Artist", value: \.artist, comparator: .localizedStandard) { Text(song($0)?.artistName ?? "").lineLimit(1) }
                .width(min: 100, ideal: 180)
            TableColumn("Album", value: \.album, comparator: .localizedStandard) { Text(song($0)?.album ?? "").lineLimit(1) }
                .width(min: 100, ideal: 200)
            TableColumn("Genre") { Text(song($0)?.genre ?? "").lineLimit(1) }
                .width(min: 60, ideal: 110)
            TableColumn("\u{2606}") { row in
                if let song = song(row), model.isStarred(song) {
                    Image(systemName: "star.fill").foregroundStyle(selection.contains(row.id) ? Color.primary : .musicAccent)
                }
            }
            .width(min: 24, ideal: 28, max: 36)
            TableColumn("Plays", value: \.plays) { row in
                let plays = song(row)?.playCount ?? 0
                Text(plays > 0 ? String(plays) : "").monospacedDigit()
            }
            .width(min: 40, ideal: 50, max: 70)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let song = list?.item(at: id) { SongMenuItems(song: song) }
        } primaryAction: { ids in
            if let id = ids.first { play(id) }
        }
        .overlay {
            if list?.count ?? 0 == 0 {
                if let error = list?.error { LoadFailedView(message: error) { list = nil; reload += 1 } }
                else if list == nil { songsPlaceholder }
                else if !model.searchText.isEmpty { ContentUnavailableView.search(text: model.searchText) }
                else { ContentUnavailableView("No Songs", systemImage: "music.note") }
            }
        }
        .navigationTitle("Songs")
        .task(id: [String(model.libraryVersion), String(reload), model.searchText, String(describing: sortOrder.first?.keyPath), String(sortOrder.first?.order == .reverse)]) {
            if list != nil { try? await Task.sleep(for: .milliseconds(150)) }  // typing
            guard !Task.isCancelled else { return }
            let (sort, descending) = databaseSort
            let found = await model.songPages(sort: sort, descending: descending, query: model.query)
            guard !Task.isCancelled else { return }
            selection = []
            list = found
        }
    }

    @State private var reload = 0

    /// The clicked column as a database order. Play counts start with the most played.
    private var databaseSort: (SongSort, Bool) {
        let first = sortOrder.first
        let reverse = first?.order == .reverse
        switch first?.keyPath {
        case \Row.title: return (.title, reverse)
        case \Row.duration: return (.duration, reverse)
        case \Row.album: return (.album, reverse)
        case \Row.plays: return (.mostPlayed, reverse)
        default: return (.artist, reverse)
        }
    }

    private func song(_ row: Row) -> Song? { list?.item(at: row.id) }

    private func titleCell(_ row: Row, _ song: Song) -> some View {
        Group {
            // Accent marks would be red on the blue selection; selected rows use the table's own colors.
            let selected = selection.contains(row.id)
            HStack {
                Text(song.title).lineLimit(1)
                    .foregroundStyle(model.player.current?.id == song.id && !selected ? Color.musicAccent : .primary)
                Spacer(minLength: 4)
                RowMenu(tint: selected ? .primary : .musicAccent) { SongMenuItems(song: song) }
            }
        }
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

    /// Queues up to 500 rows in the shown order, starting at `index`.
    private func play(_ index: Row.ID) {
        guard let list else { return }
        Task {
            let songs = await list.items(offset: index, limit: 500)
            if !songs.isEmpty { model.player.play(songs, startAt: 0) }
        }
    }
}
