import Preferences
import SwiftUI

/// The Songs page table on iPad: a list over the row numbers of `list`, so rows load their page only when shown.
/// Tap plays, a long press opens the menu of the row or of the selection (Edit, or ⌘/⇧-click with a pointer),
/// rows drag onto sidebar playlists. Same inputs as the Mac table.
struct TrackTable<Item: TrackTableItem>: View {
    typealias Column = AppearanceSettings.SongsTableColumn

    @Environment(AppModel.self) private var model
    let list: PagedList<Item>?
    @Binding var sort: Column
    @Binding var descending: Bool
    let onPlay: (Int) -> Void
    var bottomInset: CGFloat = 0
    var scrollKey = ""
    var columns = AppPreferences.shared.appearance.tableColumns(device: Item.isDevice)
    var rowHeight = AppPreferences.shared.appearance.listDensity.tableRowHeight
    @State private var selection = Set<Int>()

    var body: some View {
        let shown = columns.filter(Item.columns.contains)
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section {
                    ForEach(0..<(list?.count ?? 0), id: \.self) { row in
                        TrackTableRow(item: list?.item(at: row), columns: shown)
                            .frame(minHeight: 44)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .draggable(list?.item(at: row)?.dragText ?? "")
                    }
                } header: {
                    TrackTableHeader<Item>(columns: shown, sort: $sort, descending: $descending)
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: Int.self) { rows in
                let items = rows.sorted().compactMap { list?.item(at: $0) }
                if let first = rows.min(), !items.isEmpty { Item.menuItems(items, model) { onPlay(first) } }
            } primaryAction: { rows in
                if let first = rows.min() { onPlay(first) }
            }
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Columns", systemImage: "tablecells") {
                        ForEach(Item.columns.filter { $0 != .title }, id: \.self) { column in
                            Toggle(column.title, isOn: Binding(
                                get: { AppPreferences.shared.appearance.shows(column, device: Item.isDevice) },
                                set: { AppPreferences.shared.appearance.setShown(column, $0, device: Item.isDevice) }))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }  // selects rows for one menu
            }
            .onChange(of: scrollKey) {
                selection = []
                proxy.scrollTo(0, anchor: .top)
            }
        }
    }
}

private struct TrackTableRow<Item: TrackTableItem>: View {
    @Environment(AppModel.self) private var model
    let item: Item?
    let columns: [AppearanceSettings.SongsTableColumn]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(columns, id: \.self) { column in
                HStack(spacing: 0) { cell(column) }.columnFrame(column)  // an empty cell keeps its width
            }
        }
        .opacity(item.map { $0.isAvailable(model) } ?? true ? 1 : 0.4)
    }

    @ViewBuilder private func cell(_ column: AppearanceSettings.SongsTableColumn) -> some View {
        if let item {
            switch column {
            case .rating:
                if let rating = item.shownRating(model) {
                    RatingStars(rating: rating, size: 11, hidesEmpty: true) { item.ratingSetter(model)?($0) }
                        .disabled(item.ratingSetter(model) == nil)
                }
            case .star:
                if item.isStarred(model) { Image(systemName: "star.fill").foregroundStyle(Color.musicAccent) }
            case .title:
                HStack(spacing: 4) {
                    if let badge = item.badge(model) { Image(systemName: badge).foregroundStyle(.secondary).imageScale(.small) }
                    Text(item.cellText(column)).foregroundStyle(item.isCurrent(model) ? Color.musicAccent : .primary)
                }
                .lineLimit(1)
            default:
                Text(item.cellText(column)).lineLimit(1).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            Text(column == .title ? "…" : "").foregroundStyle(.tertiary)
        }
    }
}

/// Column titles: a sortable one sorts on tap, again in the other direction. The toolbar menu shows or hides columns.
private struct TrackTableHeader<Item: TrackTableItem>: View {
    let columns: [AppearanceSettings.SongsTableColumn]
    @Binding var sort: AppearanceSettings.SongsTableColumn
    @Binding var descending: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(columns, id: \.self) { column in
                title(column).columnFrame(column)
            }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder private func title(_ column: AppearanceSettings.SongsTableColumn) -> some View {
        let text = Text(column.layout.title).lineLimit(1)
        if Item.sortable(column) {
            Button {
                if sort == column { descending.toggle() } else { sort = column; descending = false }
            } label: {
                HStack(spacing: 2) {
                    text
                    if sort == column { Image(systemName: descending ? "chevron.down" : "chevron.up").imageScale(.small) }
                }
            }
            .buttonStyle(.plain)
        } else {
            text
        }
    }
}

private extension View {
    /// Text columns share the free width; the others keep their width, so the columns line up row to row.
    @ViewBuilder func columnFrame(_ column: AppearanceSettings.SongsTableColumn) -> some View {
        if column.isFlexible {
            frame(minWidth: column.layout.min, maxWidth: .infinity, alignment: .leading)
        } else {
            frame(width: column == .rating ? 80 : column.layout.ideal, alignment: .leading)
        }
    }
}
