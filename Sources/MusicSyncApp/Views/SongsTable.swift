import AppKit
import Library
import Observation
import SwiftUI
import Subsonic

/// The Songs page table, in AppKit: a SwiftUI `Table` stalls for seconds each time tens of thousands of rows
/// come or go. Rows are the items of `list`; a cell redraws when its page loads or what it shows changes.
/// Click, ⌘-click and ⇧-click select; double-click and Return play; selected rows drag onto sidebar playlists.
struct SongsTable: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let list: PagedList<Song>?
    @Binding var sort: SongSort
    @Binding var descending: Bool
    let onPlay: (Int) -> Void
    /// Rows scroll on under the player at the bottom, as in the SwiftUI table.
    var bottomInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = Table()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for column in Column.allCases { table.addTableColumn(column.tableColumn) }
        table.sortDescriptors = [NSSortDescriptor(key: Column(sort)?.rawValue ?? Column.artist.rawValue, ascending: !descending)]
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.menuForRows = { [weak coordinator = context.coordinator] in coordinator?.menu($0) }
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.playSelected() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        scroll.contentInsets.bottom = bottomInset
        scroll.scrollerInsets.bottom = bottomInset
        guard coordinator.list !== list, let table = coordinator.table else { return }
        coordinator.list = list
        coordinator.observed = []
        table.deselectAll(nil)
        if table.numberOfRows == 0 { table.reloadData() } else { table.noteNumberOfRowsChanged() }
        table.scrollRowToVisible(0)
        coordinator.fillLiveRows()
    }

    /// The columns, as on the SwiftUI table before. A sortable column names its database order.
    enum Column: String, CaseIterable {
        case title, time, artist, album, genre, star, rating, plays

        init?(_ sort: SongSort) {
            guard let column = Self.allCases.first(where: { $0.sort == sort }) else { return nil }
            self = column
        }

        var sort: SongSort? {
            switch self {
            case .title: .title
            case .time: .duration
            case .artist: .artist
            case .album: .album
            case .rating: .rating
            case .plays: .mostPlayed
            case .genre, .star: nil
            }
        }

        @MainActor var tableColumn: NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue))
            let (title, min, ideal, max): (String, CGFloat, CGFloat, CGFloat) = switch self {
            case .title: ("Title", 180, 280, 10_000)
            case .time: ("Time", 44, 52, 70)
            case .artist: ("Artist", 100, 180, 10_000)
            case .album: ("Album", 100, 200, 10_000)
            case .genre: ("Genre", 60, 110, 10_000)
            case .star: ("\u{2606}", 24, 28, 36)
            case .rating: ("Rating", 70, 74, 90)
            case .plays: ("Plays", 40, 50, 70)
            }
            column.title = title
            column.minWidth = min
            column.width = ideal
            column.maxWidth = max
            if sort != nil { column.sortDescriptorPrototype = NSSortDescriptor(key: rawValue, ascending: true) }
            return column
        }
    }

    /// The table view with the keys and the context menu of the old SwiftUI table.
    final class Table: NSTableView {
        var menuForRows: (([Int]) -> NSMenu?)?
        var onReturn: (() -> Void)?

        /// The selection when the clicked row is in it, else the clicked row alone.
        override func menu(for event: NSEvent) -> NSMenu? {
            let row = row(at: convert(event.locationInWindow, from: nil))
            guard row >= 0 else { return nil }
            _ = super.menu(for: event)
            return menuForRows?(selectedRowIndexes.contains(row) ? Array(selectedRowIndexes) : [row])
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76, !selectedRowIndexes.isEmpty { onReturn?() }
            else if event.keyCode == 53 { deselectAll(nil) }  // Escape, as in the album and playlist lists
            else { super.keyDown(with: event) }
        }
    }

    /// Gray selection, as in Music; the default one is the blue system accent.
    final class RowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { false }
            set {}
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SongsTable?
        var list: PagedList<Song>?
        weak var table: Table?
        /// Columns with a tracked cell of a loaded song. All cells of a column read the same properties,
        /// so one tracked cell is enough; tracking every cell slows each reload down the longer the app runs.
        var observed: Set<Column> = []
        private var refreshPending = false

        func numberOfRows(in tableView: NSTableView) -> Int { list?.count ?? 0 }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
            return view(column, row: row, reusing: tableView.makeView(withIdentifier: column.cellID, owner: nil))
        }

        /// Fills the rows the table holds again, in place: adding new cell views to a big window is slow,
        /// and `reloadData` makes new ones each time.
        func fillLiveRows() {
            guard let table else { return }
            table.enumerateAvailableRowViews { rowView, row in
                for (index, tableColumn) in table.tableColumns.enumerated() {
                    guard let column = Column(rawValue: tableColumn.identifier.rawValue), let old = rowView.view(atColumn: index) as? NSView else { continue }
                    _ = view(column, row: row, reusing: old)
                }
            }
        }

        /// Reads are tracked: a page that loads, a new star or rating redraws the shown rows.
        private func view(_ column: Column, row: Int, reusing reused: NSView?) -> NSView {
            guard !observed.contains(column) else { return cell(column, list?.item(at: row), reusing: reused) }
            return withObservationTracking {
                let song = list?.item(at: row)
                if song != nil { observed.insert(column) }
                return cell(column, song, reusing: reused)
            } onChange: { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let first = tableView.sortDescriptors.first, let column = first.key.flatMap(Column.init),
                  let sort = column.sort else { return }
            parent?.sort = sort
            parent?.descending = !first.ascending
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            list?.item(at: row).map { DragPayload.songs([$0.id], index: nil).text as NSString }
        }

        @objc func doubleClicked() {
            if let row = table?.clickedRow, row >= 0 { parent?.onPlay(row) }
        }

        func playSelected() {
            if let row = table?.selectedRowIndexes.first { parent?.onPlay(row) }
        }

        func menu(_ rows: [Int]) -> NSMenu? {
            guard let parent, let list else { return nil }
            let songs = rows.compactMap { list.item(at: $0) }
            guard let first = songs.first else { return nil }
            let items = Group { if songs.count == 1 { SongMenuItems(song: first) } else { SongsMenuItems(songs: songs) } }
            return NSHostingMenu(rootView: items.environment(parent.model))
        }

        /// Fills the rows again once per change, however many cells saw it.
        private func refresh() {
            observed = []
            guard let table, !refreshPending else { return }
            refreshPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshPending = false
                // Without a known total (server search), a loaded page may add rows.
                if table.numberOfRows != list?.count ?? 0 { table.noteNumberOfRowsChanged() }
                fillLiveRows()
            }
        }

        private func cell(_ column: Column, _ song: Song?, reusing reused: NSView?) -> NSView {
            guard let model = parent?.model else { return NSView() }
            let accent = NSColor(Color.musicAccent)
            switch column {
            case .title:
                let cell = reused as? TextCell ?? TextCell(column.cellID, menu: true)
                cell.text = song?.title ?? ""
                cell.color = song.map { model.player.current?.id == $0.id } == true ? accent : .labelColor
                cell.badge = song.flatMap { model.downloads.badge($0) }
                cell.tint = accent
                cell.alphaValue = song.map(model.downloads.isAvailable) == false ? 0.4 : 1
                cell.menuItems = song.map { song in { NSHostingMenu(rootView: SongMenuItems(song: song).environment(model)) } }
                return cell
            case .rating:
                let cell = reused as? RatingCell ?? RatingCell(column.cellID)
                cell.isHidden = song == nil || model.ratingUnsupported
                cell.rating = song.map(model.rating) ?? 0
                cell.tint = accent
                cell.onSet = { rating in song.map { model.setRating(rating, for: $0) } }
                return cell
            case .star:
                let cell = reused as? StarCell ?? StarCell(column.cellID)
                cell.tint = accent
                cell.isOn = song.map(model.isStarred) ?? false
                return cell
            default:
                let cell = reused as? TextCell ?? TextCell(column.cellID, digits: column == .time || column == .plays)
                cell.text = song.map { text(column, $0) } ?? ""
                return cell
            }
        }

        private func text(_ column: Column, _ song: Song) -> String {
            switch column {
            case .time: song.duration.map { formatTime(TimeInterval($0)) } ?? ""
            case .artist: song.artistName ?? ""
            case .album: song.album ?? ""
            case .genre: song.genre ?? ""
            case .plays: (song.playCount ?? 0) > 0 ? String(song.playCount ?? 0) : ""
            default: ""
            }
        }
    }
}

private extension SongsTable.Column {
    var cellID: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("cell-" + rawValue) }
}
