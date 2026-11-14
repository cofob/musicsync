import Library
import Subsonic
import SwiftUI

extension Color {
    private static let genrePalette: [Color] = [
        Color(red: 0.98, green: 0.14, blue: 0.24), Color(red: 0.95, green: 0.35, blue: 0.20), Color(red: 0.90, green: 0.70, blue: 0.05),
        Color(red: 0.15, green: 0.70, blue: 0.30), Color(red: 0.10, green: 0.55, blue: 0.60), Color(red: 0.30, green: 0.50, blue: 0.95),
        Color(red: 0.55, green: 0.35, blue: 0.85), Color(red: 0.95, green: 0.40, blue: 0.60), Color(red: 0.35, green: 0.35, blue: 0.40),
    ]

    /// A color picked from the genre name: the same genre has the same color on every page.
    static func genre(_ name: String) -> Color {
        genrePalette[Int(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }.magnitude % UInt(genrePalette.count))]
    }
}

/// Library > Genres: a colored tile per genre with a collage of its covers and its counts.
struct GenresView: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [GenreSummary]?
    @State private var loadError: String?

    var body: some View {
        let shown = genres.map { list in model.query.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(model.query) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Genres").font(.system(size: 30, weight: .bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 20)], spacing: 20) {
                    if let shown {
                        ForEach(shown) { genre in
                            NavigationLink(value: Route.genre(genre.name)) { GenreCollageTile(genre: genre) }.buttonStyle(CardPressStyle())
                        }
                    } else if loadError == nil {
                        ForEach(0..<12, id: \.self) { _ in PlaceholderBlock(height: 150, cornerRadius: 14) }.shimmering()
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .overlay {
            if let loadError {
                LoadFailedView(message: loadError) { Task { await load() } }
            } else if shown?.isEmpty == true {
                if model.query.isEmpty {
                    ContentUnavailableView("No Genres", systemImage: "guitars", description: Text("No album in the library has a genre."))
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
        .navigationTitle("Genres")
        .task(id: model.libraryVersion) { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            let found = try await model.browse.genres()
            if !Task.isCancelled { genres = found }
        } catch where !error.isCancellation {
            if genres == nil { loadError = error.friendlyMessage }
        } catch {}
    }
}

/// Genre tile: its color, the name and counts at the top left, and up to four covers tilted in the corner.
struct GenreCollageTile: View {
    let genre: GenreSummary
    var height: CGFloat = 150

    var body: some View {
        Color.genre(genre.name)
            .overlay(alignment: .bottomTrailing) { GenreCollage(covers: genre.covers).frame(width: height * 0.8).offset(x: 12, y: 22) }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(genre.name).font(.title3.bold()).lineLimit(2)
                    Text(genreCounts(genre)).font(.callout.weight(.medium)).opacity(0.85).lineLimit(1)
                }
                .foregroundStyle(.white).shadow(color: .black.opacity(0.25), radius: 4)
                .padding(14)
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }
}

/// "6 albums · 28 songs".
func genreCounts(_ genre: GenreSummary) -> String {
    let albums = "\(genre.albumCount) \(genre.albumCount == 1 ? "album" : "albums")"
    return genre.songCount > 0 ? "\(albums) · \(formatSongs(genre.songCount))" : albums
}

/// Two by two covers turned a little, like the artwork on Apple Music category tiles; one big cover when there are fewer than four.
struct GenreCollage: View {
    let covers: [String]

    var body: some View {
        let grid = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
        Group {
            if covers.count >= 4 {
                LazyVGrid(columns: grid, spacing: 4) {
                    ForEach(Array(covers.prefix(4).enumerated()), id: \.offset) { _, id in
                        CoverImage(id: id, size: 200, cornerRadius: 5)
                    }
                }
            } else if let first = covers.first {
                CoverImage(id: first, size: 300, cornerRadius: 6)
            }
        }
        .rotationEffect(.degrees(12))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }
}
