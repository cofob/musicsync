import Foundation

/// A song, album, playlist or artist to share.
public struct ShareTarget: Hashable, Sendable {
    public let kind: DeepLink.Kind
    public let id: String
    public let title: String
    public let artist: String?
    public let coverArt: String?

    public init(kind: DeepLink.Kind, id: String, title: String, artist: String? = nil, coverArt: String? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.artist = artist
        self.coverArt = coverArt
    }

    /// "Title — Artist", also the description of a server share.
    public var label: String { [title, artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ") }

    /// Opens the item in MusicSync.
    public var deepLink: URL { DeepLink.show(kind, id: id).url }

    /// The shared text: the label, then the server's public link or else the deep link.
    public func text(link: URL? = nil) -> String { label + "\n" + (link ?? deepLink).absoluteString }
}
