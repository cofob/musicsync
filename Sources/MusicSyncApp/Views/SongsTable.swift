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
                let rows = table.rows(in: table.visibleRect)
                guard rows.length > 0 else { return }
                table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)),
                                 columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
        }

        private func cell(_ column: Column, _ song: Song?, in tableView: NSTableView) -> NSView {
            guard let model = parent?.model else { return NSView() }
            switch column {
            case .title:
                return hosted(column, in: tableView, song.map { AnyView(SongTitleCell(song: $0).environment(model)) })
            case .rating:
                let rating = song.flatMap { song in
                    model.ratingUnsupported ? nil : AnyView(RatingStars(rating: model.rating(song), size: 10, hidesEmpty: true) { model.setRating($0, for: song) })
                }
                return hosted(column, in: tableView, rating)
            case .star:
                let cell = tableView.makeView(withIdentifier: column.cellID, owner: nil) as? NSImageView ?? starView(column)
                cell.isHidden = !(song.map(model.isStarred) ?? false)
                return cell
            default:
                let cell = tableView.makeView(withIdentifier: column.cellID, owner: nil) as? TextCell ?? TextCell(column)
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

        private func hosted(_ column: Column, in tableView: NSTableView, _ content: AnyView?) -> NSView {
            let cell = tableView.makeView(withIdentifier: column.cellID, owner: nil) as? HostingCell ?? HostingCell(column)
            cell.host.rootView = content ?? AnyView(EmptyView())
            return cell
        }

        private func starView(_ column: Column) -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite") ?? NSImage())
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            view.contentTintColor = NSColor(Color.musicAccent)
            view.identifier = column.cellID
            return view
        }
    }

    /// One line of text, truncated; times and counts use even-width digits.
    final class TextCell: NSTableCellView {
        init(_ column: Column) {
            super.init(frame: .zero)
            identifier = column.cellID
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            if column == .time || column == .plays { field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { nil }
    }

    /// A SwiftUI cell; the view is kept and only its content changes when the table reuses it.
    final class HostingCell: NSTableCellView {
        let host = NSHostingView(rootView: AnyView(EmptyView()))

        init(_ column: Column) {
            super.init(frame: .zero)
            identifier = column.cellID
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }

        required init?(coder: NSCoder) { nil }
    }
}

private extension SongsTable.Column {
    var cellID: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("cell-" + rawValue) }
}

/// Title, download badge and "•••" menu; red while the song plays, faded when it cannot play offline.
private struct SongTitleCell: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        HStack {
            Text(song.title).lineLimit(1)
                .foregroundStyle(model.player.current?.id == song.id ? Color.musicAccent : .primary)
            Spacer(minLength: 4)
            if let badge = model.downloads.badge(song) { Image(systemName: badge).font(.caption).foregroundStyle(.secondary) }
            RowMenu { SongMenuItems(song: song) }
        }
        .frame(maxHeight: .infinity)
        .opacity(model.downloads.isAvailable(song) ? 1 : 0.4)
    }
}
