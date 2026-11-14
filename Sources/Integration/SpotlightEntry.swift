import CoreSpotlight
import Foundation
import Subsonic
import UniformTypeIdentifiers

/// One album, artist or playlist in the Spotlight index. Its id is the deep link, so a picked result opens it.
public struct SpotlightEntry: Codable, Hashable, Sendable {
    public let id: String
    public let kind: DeepLink.Kind
    public let title: String
    public let subtitle: String?
    /// Local thumbnail file path.
    public let thumbnail: String?

    public init(kind: DeepLink.Kind, itemId: String, title: String, subtitle: String?, thumbnail: String?) {
        id = DeepLink.show(kind, id: itemId).url.absoluteString
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.thumbnail = thumbnail
    }

    /// Entries for the library lists. `thumbnails` maps cover art ids to local files.
    public static func entries(artists: [Artist], albums: [Album], playlists: [Playlist],
                               thumbnails: [String: URL] = [:]) -> [SpotlightEntry] {
        func thumb(_ cover: String?) -> String? { cover.flatMap { thumbnails[$0]?.path } }
        let albumSubtitle = { (a: Album) in ["Album", a.artistName, a.year.map(String.init)].compactMap { $0 }.joined(separator: " · ") }
        return artists.map { SpotlightEntry(kind: .artist, itemId: $0.id, title: $0.name, subtitle: "Artist", thumbnail: thumb($0.coverArt)) }
            + albums.map { SpotlightEntry(kind: .album, itemId: $0.id, title: $0.name, subtitle: albumSubtitle($0), thumbnail: thumb($0.coverArt)) }
            + playlists.map { SpotlightEntry(kind: .playlist, itemId: $0.id, title: $0.name, subtitle: "Playlist", thumbnail: thumb($0.coverArt)) }
    }

    public var searchableItem: CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: kind == .playlist ? .m3uPlaylist : .audio)
        attributes.title = title
        attributes.displayName = title
        attributes.contentDescription = subtitle
        attributes.thumbnailURL = thumbnail.map(URL.init(fileURLWithPath:))
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: kind.rawValue, attributeSet: attributes)
    }
}

/// What changed since the last indexing.
public struct SpotlightPlan: Equatable, Sendable {
    public var upserts: [SpotlightEntry]
    public var removals: [String]

    public init(old: [String: SpotlightEntry], new: [SpotlightEntry]) {
        upserts = new.filter { old[$0.id] != $0 }
        let ids = Set(new.map(\.id))
        removals = old.keys.filter { !ids.contains($0) }.sorted()
    }
}
