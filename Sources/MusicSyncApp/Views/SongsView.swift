import Library
import Preferences
import SwiftUI
import Subsonic

/// Every song of the library in a sortable table. Rows come in pages as they scroll in (`PagedList`);
/// the database sorts and filters. Double-click plays from the clicked row.
struct SongsView: View {
    @Environment(AppModel.self) private var model
    @State private var sort = SongsTable.Column.artist
    @State private var descending = false
    @State private var list: PagedList<Song>?

    var body: some View {
        GeometryReader { geometry in
            SongsTable(list: list, sort: $sort, descending: $descending, onPlay: play, bottomInset: geometry.safeAreaInsets.bottom,
                       scrollKey: "\(sort) \(descending) \(model.query)")
                .ignoresSafeArea(edges: .bottom)
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
        .task(id: [String(model.libraryVersion), String(reload), model.searchText, String(describing: sort), String(descending)]) {
            if list != nil { try? await Task.sleep(for: .milliseconds(150)) }  // typing
            guard !Task.isCancelled else { return }
            let found = await model.songPages(sort: sort.sort ?? .artist, descending: descending, query: model.query)
            guard !Task.isCancelled else { return }
            list = found
        }
    }

    @State private var reload = 0

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
    private func play(_ index: Int) {
        guard let list else { return }
        Task {
            let songs = await list.items(offset: index, limit: 500)
            if !songs.isEmpty { model.player.play(songs, startAt: 0) }
        }
    }
}
