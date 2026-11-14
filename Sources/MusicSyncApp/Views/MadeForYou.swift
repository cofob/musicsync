import Preferences
import Recommend
import Subsonic
import SwiftUI

/// Home: the "Made for You" mix cards and the "Because You Listened to" shelves. Hidden without the local mirror.
struct MadeForYouSection: View {
    @Environment(AppModel.self) private var model
    /// `.madeForYou` draws the mix cards, `.because` the shelves; Settings > Library orders them.
    var part = HomeShelf.madeForYou

    var body: some View {
        let mixes = model.mixes
        if mixes.isAvailable, !mixes.mixes.isEmpty {
            if part == .because {
                ForEach(mixes.because) { BecauseShelf(mix: $0) }
            } else {
                mixCards(mixes)
            }
        }
    }

    private func mixCards(_ mixes: MixModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ShelfHeader(title: "Made for You")
                Spacer()
                Button("New Mixes", systemImage: "arrow.clockwise") { Task { await mixes.load(refresh: true) } }
                    .buttonStyle(CircleIconStyle(size: 28)).help("Make New Mixes")
            }
            HorizontalShelf {
                ForEach(mixes.mixes) { MixCard(mix: $0).frame(width: 180) }
            }
        }
    }
}

/// Mix art: a collage of the first covers under the mix color, with the title, like Apple Music's mixes.
struct MixArtwork: View {
    let mix: Mix
    let songs: [Song]
    var cornerRadius: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            let covers = Array(uniqueCovers.prefix(4))
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: mix.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                if covers.count == 4 {
                    VStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<2, id: \.self) {
                                    CoverImage(id: covers[row * 2 + $0], size: 300, cornerRadius: 0).frame(width: side / 2, height: side / 2)
                                }
                            }
                        }
                    }
                } else if let cover = covers.first {
                    CoverImage(id: cover, size: 600, cornerRadius: 0)
                }
                LinearGradient(stops: [.init(color: mix.colors[0].opacity(0.1), location: 0), .init(color: mix.colors[1].opacity(0.95), location: 0.75)],
                               startPoint: .top, endPoint: .bottom)
                Text(mix.kind == .because ? "Station" : mix.title)
                    .font(.system(size: side * 0.12, weight: .heavy)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                    .padding(side * 0.07)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var uniqueCovers: [String] {
        var seen = Set<String>()
        return songs.compactMap(\.coverArt).filter { seen.insert($0).inserted }
    }
}

extension Mix {
    /// Gradient colors: fixed per kind, Daily Mixes by number.
    var colors: [Color] {
        switch kind {
        case .favorites: [Color(red: 1, green: 0.35, blue: 0.5), Color(red: 0.85, green: 0.1, blue: 0.25)]
        case .heavyRotation: [Color(red: 1, green: 0.62, blue: 0.2), Color(red: 0.9, green: 0.3, blue: 0.1)]
        case .rediscover: [Color(red: 0.7, green: 0.45, blue: 1), Color(red: 0.42, green: 0.2, blue: 0.75)]
        case .fresh: [Color(red: 0.35, green: 0.85, blue: 0.6), Color(red: 0.05, green: 0.55, blue: 0.45)]
        case .deepCuts: [Color(red: 0.4, green: 0.55, blue: 1), Color(red: 0.15, green: 0.22, blue: 0.7)]
        case .because: [Color(white: 0.55), Color(white: 0.25)]
        case .daily:
            [[Color(red: 0.3, green: 0.75, blue: 1), Color(red: 0.05, green: 0.4, blue: 0.75)],
             [Color(red: 1, green: 0.5, blue: 0.7), Color(red: 0.7, green: 0.15, blue: 0.5)],
             [Color(red: 1, green: 0.8, blue: 0.3), Color(red: 0.85, green: 0.45, blue: 0.05)],
             [Color(red: 0.45, green: 0.9, blue: 0.85), Color(red: 0.1, green: 0.5, blue: 0.6)]][max(0, (Int(id.dropFirst(6)) ?? 1) - 1) % 4]
        }
    }
}

/// Mix card: art with the title, then one line of description, like Apple Music. Opens the mix page.
private struct MixCard: View {
    @Environment(AppModel.self) private var model
    let mix: Mix

    var body: some View {
        NavigationLink(value: Route.mix(mix.id)) {
            VStack(alignment: .leading, spacing: 2) {
                MixArtwork(mix: mix, songs: model.mixes.songs(of: mix))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .padding(.bottom, 6)
                // One line on every card keeps the artwork the same size.
                Text(mix.subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { MixMenuItems(mix: mix) }
    }
}

struct MixMenuItems: View {
    @Environment(AppModel.self) private var model
    let mix: Mix

    var body: some View {
        Button("Play", systemImage: "play.fill") { model.mixes.play(mix, shuffled: false) }
        Button("Shuffle", systemImage: "shuffle") { model.mixes.play(mix, shuffled: true) }
        Divider()
        Button("Save as Playlist…", systemImage: "text.badge.plus") { model.mixes.save(mix) }
    }
}

/// "Because You Listened to <song>": a short station as song cards; a click plays the shelf from that song.
private struct BecauseShelf: View {
    @Environment(AppModel.self) private var model
    let mix: Mix

    var body: some View {
        let songs = model.mixes.songs(of: mix)
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: "Because You Listened to \(mix.title)") { model.show(.mix(mix.id)) }.lineLimit(1)
            HorizontalShelf {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongCard(song: song) { model.mixes.play(mix, startAt: index) }.frame(width: 150)
                }
            }
        }
    }
}

private struct SongCard: View {
    let song: Song
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 2) {
                CoverImage(id: song.coverArt, size: 300, cornerRadius: 8)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .padding(.bottom, 6)
                Text(song.title).lineLimit(1)
                Text(song.artistName ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SongMenuItems(song: song) }
    }
}

/// Horizontal row of cards that bleeds into the page margins.
private struct HorizontalShelf<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 18) { content }
                // Room for the card shadows, which the scroll view would clip.
                .padding(.horizontal, 32).padding(.vertical, 20)
        }
        .scrollIndicators(.never)
        .padding(.horizontal, -32).padding(.vertical, -20)
    }
}

/// "Create Station" for song, album, artist and playlist menus; hidden without the local mirror.
struct StationButton: View {
    @Environment(AppModel.self) private var model
    let seed: MixModel.StationSeed

    var body: some View {
        if model.mixes.isAvailable {
            Button("Create Station", systemImage: "dot.radiowaves.left.and.right") { model.mixes.startStation(seed) }
        }
    }
}

/// AutoPlay switch (∞) for the queue panel.
struct AutoPlayButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mixes = model.mixes
        if mixes.isAvailable {
            Button { mixes.autoPlay.toggle() } label: {
                Image(systemName: "infinity").font(.body.weight(.bold))
                    .foregroundStyle(.white.opacity(mixes.autoPlay ? 1 : 0.6))
                    .frame(width: 34, height: 24)
                    .background(.white.opacity(mixes.autoPlay ? 0.25 : 0), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(mixes.autoPlay ? "AutoPlay: similar songs play when the queue ends" : "Turn On AutoPlay")
            .accessibilityLabel("AutoPlay")
            .accessibilityValue(mixes.autoPlay ? "On" : "Off")
        }
    }
}
