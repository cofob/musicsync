import AppKit
import Library
import Observation
import Preferences
import SwiftUI
import Subsonic

/// A row of `TrackTable`: a library song or an iPod track.
@MainActor protocol TrackTableItem: Sendable {
    /// Shows the iPod column settings, not the library ones.
    static var isDevice: Bool { get }
    /// Columns of the header menu.
    static var columns: [AppearanceSettings.SongsTableColumn] { get }
    static func sortable(_ column: AppearanceSettings.SongsTableColumn) -> Bool
    func cellText(_ column: AppearanceSettings.SongsTableColumn) -> String
    func isCurrent(_ model: AppModel) -> Bool
    func badge(_ model: AppModel) -> String?
    func isAvailable(_ model: AppModel) -> Bool
    /// nil hides the stars.
    func shownRating(_ model: AppModel) -> Int?
    /// nil: the rating cannot change.
    func ratingSetter(_ model: AppModel) -> ((Int) -> Void)?
    func isStarred(_ model: AppModel) -> Bool
    var dragText: String? { get }
    /// Context menu of `items`; `play` plays from the first row.
    static func menu(_ items: [Self], _ model: AppModel, play: @escaping () -> Void) -> NSMenu?
}

extension TrackTableItem {
    func isCurrent(_ model: AppModel) -> Bool { false }
    func badge(_ model: AppModel) -> String? { nil }
    func isAvailable(_ model: AppModel) -> Bool { true }
    func ratingSetter(_ model: AppModel) -> ((Int) -> Void)? { nil }
    func isStarred(_ model: AppModel) -> Bool { false }
    var dragText: String? { nil }
}

typealias SongsTable = TrackTable<Song>

/// The Songs page table, in AppKit: a SwiftUI `Table` stalls for seconds each time tens of thousands of rows
/// come or go. Rows are the items of `list`; a cell redraws when its page loads or what it shows changes.
/// Click, ⌘-click and ⇧-click select; double-click and Return play; selected rows drag onto sidebar playlists.
struct TrackTable<Item: TrackTableItem>: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let list: PagedList<Item>?
    @Binding var sort: Column
    @Binding var descending: Bool
    let onPlay: (Int) -> Void
    /// Rows scroll on under the player at the bottom, as in the SwiftUI table.
    var bottomInset: CGFloat = 0
    /// A new list scrolls to the top only when this changes (sort, filter); a library refresh keeps the place.
    var scrollKey = ""
    /// Settings > Appearance; read here so that a change updates the table.
    var columns = AppPreferences.shared.appearance.tableColumns(device: Item.isDevice)
    var rowHeight = AppPreferences.shared.appearance.listDensity.tableRowHeight

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = Table()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle  // the text columns with `autoresizingMask` share the width
        table.rowSizeStyle = .custom
        for column in Item.columns {
            let tableColumn = column.tableColumn
            if Item.sortable(column) { tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true) }
            table.addTableColumn(tableColumn)
        }
        table.headerView?.menu = context.coordinator.headerMenu()
        table.sortDescriptors = [NSSortDescriptor(key: sort.rawValue, ascending: !descending)]
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
        coordinator.show(columns, rowHeight: rowHeight)
        guard coordinator.list !== list, let table = coordinator.table else { return }
        coordinator.list = list
        coordinator.observed = []
        table.deselectAll(nil)
        if table.numberOfRows == 0 { table.reloadData() } else { table.noteNumberOfRowsChanged() }
        if coordinator.scrollKey != scrollKey { table.scrollRowToVisible(0) }
        coordinator.scrollKey = scrollKey
        coordinator.fillLiveRows()
    }

    typealias Column = AppearanceSettings.SongsTableColumn

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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: TrackTable?
        var list: PagedList<Item>?
        weak var table: Table?
        /// Columns with a tracked cell of a loaded song. All cells of a column read the same properties,
        /// so one tracked cell is enough; tracking every cell slows each reload down the longer the app runs.
        var observed: Set<Column> = []
        var scrollKey: String?
        private var refreshPending = false
        private var shown: ([Column], CGFloat)?

        /// Puts the shown columns in their order and hides the others; a row height change redraws the rows.
        func show(_ columns: [Column], rowHeight: CGFloat) {
            let columns = columns.filter(Item.columns.contains)
            guard let table, shown.map({ $0 != columns || $1 != rowHeight }) ?? true else { return }
            shown = nil  // the moves below are not the user's
            for (index, column) in columns.enumerated() {
                let from = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
                if from >= 0, from != index { table.moveColumn(from, toColumn: index) }
            }
            for tableColumn in table.tableColumns {
                tableColumn.isHidden = !(Column(rawValue: tableColumn.identifier.rawValue).map(columns.contains) ?? false)
            }
            table.sizeToFit()  // the title column takes the width of hidden columns, or gives it up for new ones
            table.rowHeight = rowHeight
            shown = (columns, rowHeight)
        }

        /// The header menu of Music: a checkmark for each shown column.
        func headerMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let settings = AppPreferences.shared.appearance
            for column in Item.columns {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn), keyEquivalent: "")
                item.target = self
                item.representedObject = column.rawValue
                item.state = settings.shows(column, device: Item.isDevice) ? .on : .off
                item.isEnabled = column != .title
                menu.addItem(item)
            }
        }

        @objc func toggleColumn(_ item: NSMenuItem) {
            guard let column = (item.representedObject as? String).flatMap(Column.init) else { return }
            AppPreferences.shared.appearance.setShown(column, item.state != .on, device: Item.isDevice)
        }

        /// A column dragged to another place keeps it.
        func tableViewColumnDidMove(_ notification: Notification) {
            guard let table, let shown, !table.tableColumns.isEmpty else { return }
            let order = table.tableColumns.filter { !$0.isHidden }.compactMap { Column(rawValue: $0.identifier.rawValue) }
            if order != shown.0 { AppPreferences.shared.appearance.setTableColumns(order, device: Item.isDevice) }
        }

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
            guard !observed.contains(column) else { return cell(column, row, list?.item(at: row), reusing: reused) }
            return withObservationTracking {
                let item = list?.item(at: row)
                if item != nil { observed.insert(column) }
                return cell(column, row, item, reusing: reused)
            } onChange: { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let first = tableView.sortDescriptors.first, let column = first.key.flatMap(Column.init),
                  Item.sortable(column) else { return }
            parent?.sort = column
            parent?.descending = !first.ascending
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            list?.item(at: row)?.dragText.map { $0 as NSString }
        }

        @objc func doubleClicked() {
            if let row = table?.clickedRow, row >= 0 { parent?.onPlay(row) }
        }

        func playSelected() {
            if let row = table?.selectedRowIndexes.first { parent?.onPlay(row) }
        }

        func menu(_ rows: [Int]) -> NSMenu? {
            guard let parent, let list else { return nil }
            return Item.menu(rows.compactMap { list.item(at: $0) }, parent.model) { parent.onPlay(rows[0]) }
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

        private func cell(_ column: Column, _ row: Int, _ item: Item?, reusing reused: NSView?) -> NSView {
            guard let model = parent?.model else { return NSView() }
            let accent = NSColor(Color.musicAccent)
            switch column {
            case .title:
                let cell = reused as? TextCell ?? TextCell(column.cellID, menu: true)
                cell.text = item?.cellText(.title) ?? ""
                cell.color = item?.isCurrent(model) == true ? accent : .labelColor
                cell.badge = item?.badge(model)
                cell.tint = accent
                cell.alphaValue = item?.isAvailable(model) == false ? 0.4 : 1
                cell.menuItems = item.map { item in { [weak self] in Item.menu([item], model) { self?.parent?.onPlay(row) } } }
                return cell
            case .rating:
                let cell = reused as? RatingCell ?? RatingCell(column.cellID)
                let rating = item?.shownRating(model)
                cell.isHidden = rating == nil
                cell.rating = rating ?? 0
                cell.tint = accent
                cell.onSet = item?.ratingSetter(model)
                return cell
            case .star:
                let cell = reused as? StarCell ?? StarCell(column.cellID)
                cell.tint = accent
                cell.isOn = item?.isStarred(model) ?? false
                return cell
            default:
                let cell = reused as? TextCell ?? TextCell(column.cellID, digits: [.time, .plays, .track, .year, .bitRate].contains(column))
                cell.text = item?.cellText(column) ?? ""
                return cell
            }
        }
    }
}

extension Song: TrackTableItem {
    static var isDevice: Bool { false }
    static var columns: [AppearanceSettings.SongsTableColumn] { AppearanceSettings.SongsTableColumn.allCases }
    static func sortable(_ column: AppearanceSettings.SongsTableColumn) -> Bool { column.sort != nil }

    func cellText(_ column: AppearanceSettings.SongsTableColumn) -> String {
        switch column {
        case .title: title
        case .time: duration.map { formatTime(TimeInterval($0)) } ?? ""
        case .artist: artistName ?? ""
        case .album: album ?? ""
        case .genre: genre ?? ""
        case .plays: (playCount ?? 0) > 0 ? String(playCount ?? 0) : ""
        case .track: track.map(String.init) ?? ""
        case .year: year.map(String.init) ?? ""
        case .added: formatDay(created) ?? ""
        case .bitRate: bitRate.map { "\($0) kbps" } ?? ""
        case .size: size.map { formatBytes(Int64($0)) } ?? ""
        case .rating, .star: ""
        }
    }

    func isCurrent(_ model: AppModel) -> Bool { model.player.current?.id == id }
    func badge(_ model: AppModel) -> String? { model.downloads.badge(self) }
    func isAvailable(_ model: AppModel) -> Bool { model.downloads.isAvailable(self) }
    func shownRating(_ model: AppModel) -> Int? { model.ratingUnsupported ? nil : model.rating(self) }
    func ratingSetter(_ model: AppModel) -> ((Int) -> Void)? { { model.setRating($0, for: self) } }
    func isStarred(_ model: AppModel) -> Bool { model.isStarred(self) }
    var dragText: String? { DragPayload.songs([id], index: nil).text }

    static func menu(_ songs: [Song], _ model: AppModel, play: @escaping () -> Void) -> NSMenu? {
        guard let first = songs.first else { return nil }
        let items = Group { if songs.count == 1 { SongMenuItems(song: first) } else { SongsMenuItems(songs: songs) } }
        return NSHostingMenu(rootView: items.environment(model))
    }
}

private extension SongsTable.Column {
    var cellID: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("cell-" + rawValue) }
}

/// A sortable column names its database order.
extension SongsTable.Column {
    var sort: SongSort? {
        switch self {
        case .title: .title
        case .time: .duration
        case .artist: .artist
        case .album: .album
        case .rating: .rating
        case .plays: .mostPlayed
        case .added: .newest
        case .track, .genre, .star, .year, .bitRate, .size: nil
        }
    }

    /// Name in the header menu.
    @MainActor var title: String { self == .star ? "Favorite" : tableColumn.title }

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
        case .track: ("#", 24, 30, 44)
        case .year: ("Year", 40, 48, 60)
        case .added: ("Date Added", 80, 96, 140)
        case .bitRate: ("Bit Rate", 60, 72, 100)
        case .size: ("Size", 60, 80, 100)
        }
        column.title = title
        column.minWidth = min
        column.width = ideal
        column.maxWidth = max
        column.resizingMask = [.title, .artist, .album, .genre].contains(self) ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        return column
    }
}
