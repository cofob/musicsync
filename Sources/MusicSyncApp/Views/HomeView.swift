import Preferences
import SwiftUI
import Subsonic

/// Home: horizontal shelves of albums from `getAlbumList2` (newest, recent, frequent, random).
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    Text("Home").font(.system(size: 34, weight: .bold))
                    Spacer()
                    NavigationLink(value: Route.stats) { Label("Your Stats", systemImage: "chart.bar.fill") }.buttonStyle(FilledCapsuleStyle())
                }
                if model.shelves.isEmpty && model.libraryError == nil { placeholder }
                // The order and the shown sections come from Settings > Library.
                if !model.shelves.isEmpty {
                    ForEach(AppPreferences.shared.home.visible, id: \.self) { kind in
                        switch kind {
                        case .madeForYou, .because: MadeForYouSection(part: kind)
                        // Top Picks for this time of day when the history has them, else the newest albums.
                        default: if let shelf = model.shelves.first(where: { kind == .topPicks && $0.id == "picks" })
                            ?? model.shelves.first(where: { $0.id == kind.listType }) { albumShelf(shelf, featured: kind == .topPicks) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 32)
        }
        .overlay {
            if let error = model.libraryError, model.shelves.isEmpty {
                LoadFailedView(message: error) { Task { await model.loadHome() } }
            }
        }
        // An empty title (not a removed one) keeps the search field at the trailing end like on other pages.
        .navigationTitle("")
        .task(id: model.libraryVersion) { await model.loadHome() }
    }
}

extension HomeShelf {
    /// `AppModel.Shelf.id` of the album shelves.
    var listType: String? {
        switch self {
        case .topPicks: "newest"
        case .recentlyPlayed: "recent"
        case .mostPlayed: "frequent"
        case .discover: "random"
        case .madeForYou, .because: nil
        }
    }
}

extension HomeView {
    /// A row of album cards; `featured` draws the big "Top Picks" cards.
    private func albumShelf(_ shelf: AppModel.Shelf, featured: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: featured ? HomeShelf.topPicks.title : shelf.title,
                        action: shelf.id == "newest" ? { model.selection = .recentlyAdded } : nil)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: featured ? 22 : 18) {
                    ForEach(shelf.albums) { album in
                        if featured {
                            FeatureCard(album: album, label: shelf.title)
                        } else {
                            AlbumCard(album: album).frame(width: 180)
                        }
                    }
                }
                // Room for the card shadows, which the scroll view would clip.
                .padding(.horizontal, 32).padding(.vertical, 20)
            }
            .scrollIndicators(.never)
            .padding(.horizontal, -32).padding(.vertical, -20)
        }
    }

    /// Shelves with gray cards while Home loads.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach([290.0, 180.0], id: \.self) { size in
                VStack(alignment: .leading, spacing: 14) {
                    PlaceholderBlock(width: 200, height: 20)
                    // An overlay keeps the overflowing row from widening the page.
                    Color.clear.frame(height: size + 50).overlay(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 20) {
                            ForEach(0..<6, id: \.self) { _ in
                                if size > 200 { PlaceholderBlock(width: size, height: size, cornerRadius: 14) } else { PlaceholderCard().frame(width: size) }
                            }
                        }
                    }
                    .clipped()
                }
            }
        }
        .shimmering()
    }
}

/// Large "Top Picks" card: the cover with its label, title and artist over a dark gradient.
private struct FeatureCard: View {
    let album: Album
    let label: String

    var body: some View {
        NavigationLink(value: Route.album(album)) {
            CoverImage(id: album.coverArt, size: 600, cornerRadius: 14)
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                        Text(album.name).font(.title3.bold()).lineLimit(2)
                        Text(album.artistName ?? "").font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).padding(.top, 40)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                }
                .albumHoverActions(album)
                .frame(width: 290, height: 290)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .contextMenu { AlbumMenuItems(album: album) }
    }
}
