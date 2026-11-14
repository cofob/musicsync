import SwiftUI

/// All tracks on the iPod; sortable columns. Rows are indexes into a `PagedList` over the sorted tracks, so the
/// table only fills the rows on screen, as the library Songs page does. Double-click plays from the clicked row.
struct DeviceSongsView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [Sort(key: .title)]
    @State private var rows: [DeviceTrack] = []
    @State private var list: PagedList<DeviceTrack>?
    @State private var selection = Set<Int>()

    /// Table row: the index of a track in `rows`.
    private struct Row: Identifiable { let id: Int }

    /// A column's sort. The table only hands it back in `sortOrder`; the tracks are sorted with `track`.
    private struct Sort: SortComparator {
        enum Key { case title, duration, artist, album, rating, plays, size }
        let key: Key
        var order = SortOrder.forward

        func compare(_ a: Row, _ b: Row) -> ComparisonResult { .orderedSame }

        var track: KeyPathComparator<DeviceTrack> {
            var comparator: KeyPathComparator<DeviceTrack> = switch key {
            case .title: KeyPathComparator(\.title, comparator: .localizedStandard)
            case .duration: KeyPathComparator(\.duration)
            case .artist: KeyPathComparator(\.artist, comparator: .localizedStandard)
            case .album: KeyPathComparator(\.album, comparator: .localizedStandard)
            case .rating: KeyPathComparator(\.rating)
            case .plays: KeyPathComparator(\.plays)
            case .size: KeyPathComparator(\.size)
            }
            comparator.order = order
            return comparator
        }
    }

    var body: some View {
        Table(tableRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", sortUsing: Sort(key: .title)) { row in cell(row, titleCell) }
                .width(min: 180, ideal: 260)
            TableColumn("Time", sortUsing: Sort(key: .duration)) { row in
                cell(row) { Text(formatTime($1.duration)).monospacedDigit() }
            }
                .width(min: 50, ideal: 60, max: 80)
            TableColumn("Artist", sortUsing: Sort(key: .artist)) { row in
                cell(row) { Text($1.artist).lineLimit(1) }
            }
            TableColumn("Album", sortUsing: Sort(key: .album)) { row in
                cell(row) { Text($1.album).lineLimit(1) }
            }
            TableColumn("Rating", sortUsing: Sort(key: .rating)) { row in cell(row, ratingCell) }
                .width(min: 50, ideal: 70, max: 90)
            TableColumn("Plays", sortUsing: Sort(key: .plays)) { row in
                cell(row) { Text(String($1.plays)).monospacedDigit() }
            }
                .width(min: 40, ideal: 50, max: 70)
            TableColumn("Size", sortUsing: Sort(key: .size)) { row in
                cell(row) { Text(formatBytes($1.size)).foregroundStyle(.secondary) }
            }
                .width(min: 60, ideal: 80, max: 100)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first { Button("Play", systemImage: "play.fill") { play(id) } }
            if !ids.isEmpty {
                Divider()
                DeleteFromIPodButton { model.sync.tracksToDelete = ids.sorted().filter { $0 < rows.count }.map { rows[$0] } }
            }
        } primaryAction: { ids in
            if let id = ids.first { play(id) }
        }
        .overlay {
            if model.ipod.snapshot == nil || list == nil {
                ProgressView()
            } else if rows.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note")
            }
        }
        .navigationTitle("Songs")
        .task(id: [String(model.ipod.version), model.searchText, String(describing: sortOrder)]) {
            if list != nil { try? await Task.sleep(for: .milliseconds(150)) }  // typing
            guard !Task.isCancelled else { return }
            let query = model.query
            let all = model.ipod.snapshot?.tracks ?? []
            let matching = query.isEmpty ? all : all.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
                    || $0.album.localizedCaseInsensitiveContains(query)
            }
            let sorted = matching.sorted(using: sortOrder.map(\.track))
            let found = await AppModel.slices(sorted)
            guard !Task.isCancelled else { return }
            rows = sorted
            list = found
        }
    }

    private var tableRows: [Row] { list.map { (0..<$0.count).map(Row.init) } ?? [] }

    /// The track of `row` once its page is in; empty until then.
    @ViewBuilder private func cell<Content: View>(_ row: Row, @ViewBuilder _ content: @escaping (Row, DeviceTrack) -> Content) -> some View {
        if let list { PagedRow(list: list, index: row.id, content: { content(row, $0) }, placeholder: { Color.clear }) }
    }

    private func titleCell(_ row: Row, _ track: DeviceTrack) -> some View {
        HStack {
            Text(track.title).lineLimit(1)
            Spacer(minLength: 4)
            RowMenu(tint: selection.contains(row.id) ? .primary : .musicAccent) { Button("Play", systemImage: "play.fill") { play(row.id) } }
        }
    }

    private func ratingCell(_ row: Row, _ track: DeviceTrack) -> some View {
        Text(String(repeating: "★", count: track.rating)).foregroundStyle(selection.contains(row.id) ? Color.primary : .musicAccent)
    }

    /// Queues the visible rows, starting at `index`.
    private func play(_ index: Int) {
        model.play(rows, startAt: index)
    }
}
