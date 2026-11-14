import SwiftUI
import Subsonic

enum AlbumSort: String, CaseIterable, Identifiable {
    case name = "Name", artist = "Artist", year = "Year", added = "Date Added"
    var id: Self { self }

    func sorted(_ albums: [Album]) -> [Album] {
        func byName(_ a: Album, _ b: Album) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        func byArtist(_ a: Album, _ b: Album) -> ComparisonResult { (a.artistName ?? "").localizedStandardCompare(b.artistName ?? "") }
        switch self {
        case .name: return albums.sorted(by: byName)
        case .artist:
            return albums.sorted { byArtist($0, $1) == .orderedSame ? ($0.year ?? 0, $0.name) < ($1.year ?? 0, $1.name) : byArtist($0, $1) == .orderedAscending }
        case .year:
            return albums.sorted { ($0.year ?? 0) == ($1.year ?? 0) ? byName($0, $1) : ($0.year ?? 0) < ($1.year ?? 0) }
        case .added:
            return albums.sorted { ($0.created ?? "") > ($1.created ?? "") }
        }
    }
}

/// Albums grid. `recentlyAdded` fixes the order to newest first (sidebar "Recently Added").
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    var recentlyAdded = false
    @AppStorage("albumSort") private var sort = AlbumSort.name
    @State private var sorted: [Album] = []

    var body: some View {
        let shown = filtered
        Group {
            if shown.isEmpty {
                if let error = model.libraryError {
                    LoadFailedView(message: error) { Task { await model.refresh() } }
                } else if model.isLoading || model.albums.isEmpty && model.client != nil && model.libraryVersion < 2 {
                    ScrollView {
                        LazyVGrid(columns: albumGridColumns, spacing: 28) { ForEach(0..<15, id: \.self) { _ in PlaceholderCard() } }
                            .padding(.horizontal, 32).padding(.vertical, 24)
                    }
                    .disabled(true)
                } else if !model.searchText.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    ContentUnavailableView("No Albums", systemImage: "square.stack", description: Text("The library is empty."))
                }
            } else {
                AlbumGrid(albums: shown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(recentlyAdded ? "Recently Added" : "Albums")
        .toolbar {
            ToolbarItem { if model.isLoading { ProgressView().controlSize(.small) } }
            if !recentlyAdded {
                ToolbarItem {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(AlbumSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort", systemImage: "line.3.horizontal.decrease")
                    }
                    .menuIndicator(.hidden)
                }
            }
        }
        .onChange(of: model.libraryVersion, initial: true) { resort() }
        .onChange(of: sort) { resort() }
    }

    private var filtered: [Album] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.artistName ?? "").localizedCaseInsensitiveContains(query) }
    }

    private func resort() { sorted = (recentlyAdded ? .added : sort).sorted(model.albums) }
}
