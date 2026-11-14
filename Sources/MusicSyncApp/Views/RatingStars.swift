import SwiftUI
import Subsonic

/// Five stars; a click sets the rating, a click on the current last star removes it.
struct RatingStars: View {
    let rating: Int
    var size: CGFloat = 13
    /// Table cells: empty stars only on hover, so unrated rows stay clean.
    var hidesEmpty = false
    let onSet: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: size * 0.2) {
            ForEach(1...5, id: \.self) { n in
                Button { onSet(n == rating ? 0 : n) } label: {
                    Image(systemName: n <= rating ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(n <= rating ? AnyShapeStyle(Color.musicAccent) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(HitAreaButtonStyle())
                .opacity(n <= rating || !hidesEmpty || hovering ? 1 : 0)
                .accessibilityLabel("\(n) \(n == 1 ? "star" : "stars")")
            }
        }
        .onHover { hovering = $0 }
    }
}

/// "Rating" submenu of a song; hidden when the server has no ratings.
struct RatingMenu: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        if !model.ratingUnsupported {
            Picker("Rating", systemImage: "star.leadinghalf.filled",
                   selection: Binding(get: { model.rating(song) }, set: { model.setRating($0, for: song) })) {
                Text("None").tag(0)
                ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0)).tag($0) }
            }
        }
    }
}

/// Round star button of album and artist headers.
struct FavoriteButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(isOn ? "Undo Favorite" : "Favorite", systemImage: isOn ? "star.fill" : "star", action: action)
            .buttonStyle(CircleIconStyle()).help(isOn ? "Undo Favorite" : "Favorite")
    }
}
