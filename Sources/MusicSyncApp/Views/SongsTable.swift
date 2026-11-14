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
        table.deselectAll(nil)
        table.reloadData()
        table.scrollRowToVisible(0)
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
            if event.keyCode == 36 || event.keyCode == 76, !selectedRowIndexes.isEmpty { onReturn?() } else { super.keyDown(with: event) }
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
        private var refreshPending = false

        func numberOfRows(in tableView: NSTableView) -> Int { list?.count ?? 0 }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

        /// Reads are tracked: a page that loads, a new star or rating redraws the shown rows.
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
            return withObservationTracking {
                cell(column, list?.item(at: row), in: tableView)
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

        /// Reloads the shown rows once per change, however many cells saw it.
        private func refresh() {
            guard let table, !refreshPending else { return }
            refreshPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                refreshPending = false
                // Without a known total (server search), a loaded page may add rows.
                guard table.numberOfRows == list?.count ?? 0 else { return table.reloadData() }
                let rows = table.rows(in: table.visibleRect)
                guard rows.length > 0 else { return }
                table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)),
                                 columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }

        private func cell(_ column: Column, _ song: Song?, in tableView: NSTableView) -> NSView {
            guard let model = parent?.model else { return NSView() }
            let reused = tableView.makeView(withIdentifier: column.cellID, owner: nil)
            let accent = NSColor(Color.musicAccent)
            switch column {
            case .title:
                let cell = reused as? TitleCell ?? TitleCell(column.cellID)
                cell.textField?.stringValue = song?.title ?? ""
                cell.textField?.textColor = song.map { model.player.current?.id == $0.id } == true ? accent : .labelColor
                let badge = song.flatMap { model.downloads.badge($0) }
                cell.badge.image = badge.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                cell.badge.isHidden = badge == nil
                cell.needsLayout = true
                cell.more.contentTintColor = accent
                cell.more.isHidden = song == nil
                cell.alphaValue = song.map(model.downloads.isAvailable) == false ? 0.4 : 1
                cell.menuItems = { song.map { NSHostingMenu(rootView: SongMenuItems(song: $0).environment(model)) } }
                return cell
            case .rating:
                let cell = reused as? RatingCell ?? RatingCell(column.cellID)
                cell.isHidden = song == nil || model.ratingUnsupported
                cell.rating = song.map(model.rating) ?? 0
                cell.tint = accent
                cell.onSet = { rating in song.map { model.setRating(rating, for: $0) } }
                return cell
            case .star:
                let cell = reused as? NSImageView ?? starView(column)
                cell.contentTintColor = accent
                cell.isHidden = !(song.map(model.isStarred) ?? false)
                return cell
            default:
                let cell = reused as? TextCell ?? TextCell(column.cellID, digits: column == .time || column == .plays)
                cell.textField?.stringValue = song.map { text(column, $0) } ?? ""
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

        private func starView(_ column: Column) -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite") ?? NSImage())
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            view.identifier = column.cellID
            return view
        }
    }
}

private extension SongsTable.Column {
    var cellID: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("cell-" + rawValue) }
}
