import SwiftUI
import Subsonic

/// Artist list on the left, the selected artist on the right.
struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var list: PagedList<Artist>?
    @State private var selectedID: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if list == nil && model.client != nil {
                        ForEach(0..<14, id: \.self) { i in
                            HStack(spacing: 12) {
                                PlaceholderBlock(width: 40, height: 40, cornerRadius: 20)
                                PlaceholderBlock(width: CGFloat(90 + (i * 29) % 80), height: 12)
                                Spacer()
                            }
                            .padding(.horizontal, 8).frame(height: 54)
                        }
                        .shimmering()
                    }
                    if let list {
                        ForEach(0..<list.count, id: \.self) { i in
                            PagedRow(list: list, index: i) { artist in
                                ArtistRow(artist: artist, isSelected: artist.id == selectedID)
                                    .onTapGesture { selectedID = artist.id }
                            } placeholder: { Color.clear.frame(height: 54) }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(width: 280)
            Divider()
            Group {
                if let selectedID {
                    ArtistDetailView(id: selectedID, setsTitle: false).id(selectedID)
                } else {
                    ContentUnavailableView("No Artist Selected", systemImage: "music.microphone")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Artists")
        .task(id: [String(model.libraryVersion), model.searchText]) {
            if list != nil { try? await Task.sleep(for: .milliseconds(150)) }  // typing
            guard !Task.isCancelled else { return }
            let found = await model.artistPages(query: model.searchText.trimmingCharacters(in: .whitespaces))
            guard !Task.isCancelled else { return }
            list = found
            if selectedID == nil { selectedID = found.item(at: 0)?.id }
        }
    }
}

/// Round artist image (Subsonic artist cover art) with a placeholder.
struct ArtistImage: View {
    let artist: Artist

    var body: some View {
        CoverImage(id: artist.coverArt, size: 120, cornerRadius: 0, symbol: "music.microphone").clipShape(Circle())
    }
}

private struct ArtistRow: View {
    let artist: Artist
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtistImage(artist: artist).frame(width: 40, height: 40)
            Text(artist.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 54)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(isSelected ? Color.musicAccent : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) { if !isSelected { Divider().padding(.leading, 60) } }
        .contentShape(Rectangle())
    }
}
