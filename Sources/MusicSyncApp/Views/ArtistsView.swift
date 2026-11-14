import SwiftUI
import Subsonic

/// Artist list on the left, the selected artist on the right.
struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var sorted: [Artist] = []
    @State private var selectedID: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if sorted.isEmpty && model.client != nil {
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
                    ForEach(filtered) { artist in
                        ArtistRow(artist: artist, isSelected: artist.id == selectedID)
                            .onTapGesture { selectedID = artist.id }
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
        .onChange(of: model.libraryVersion, initial: true) {
            sorted = model.artists.sorted { ($0.sortName ?? $0.name).localizedStandardCompare($1.sortName ?? $1.name) == .orderedAscending }
            if selectedID == nil { selectedID = sorted.first?.id }
        }
    }

    /// "Find in Artists".
    private var filtered: [Artist] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? sorted : sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
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
