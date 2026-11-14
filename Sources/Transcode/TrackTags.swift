import Foundation

public struct TrackTags: Codable, Hashable, Sendable {
    public var title = ""
    public var artist = ""
    public var album = ""
    public var albumArtist = ""
    public var genre = ""
    public var composer = ""
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var compilation = false
    public var comment: String?

    public init(title: String = "", artist: String = "", album: String = "", albumArtist: String = "",
                genre: String = "", composer: String = "", year: Int? = nil, trackNumber: Int? = nil,
                trackTotal: Int? = nil, discNumber: Int? = nil, discTotal: Int? = nil, compilation: Bool = false,
                comment: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.compilation = compilation
        self.comment = comment
    }

    /// ffmpeg `-metadata` pairs. MP4 keys carry "N/T" values; Vorbis comments use separate total fields.
    public func metadata(vorbis: Bool) -> [(key: String, value: String)] {
        var out: [(String, String)] = [
            ("title", title), ("artist", artist), ("album", album),
            (vorbis ? "albumartist" : "album_artist", albumArtist),
            ("genre", genre), ("composer", composer),
            ("date", year.map(String.init) ?? ""), ("comment", comment ?? ""),
        ]
        if vorbis {
            out += [
                ("tracknumber", trackNumber.map(String.init) ?? ""), ("tracktotal", trackTotal.map(String.init) ?? ""),
                ("discnumber", discNumber.map(String.init) ?? ""), ("disctotal", discTotal.map(String.init) ?? ""),
            ]
        } else {
            out += [("track", Self.pair(trackNumber, trackTotal)), ("disc", Self.pair(discNumber, discTotal))]
        }
        if compilation { out.append(("compilation", "1")) }
        return out.filter { !$0.1.isEmpty }
    }

    private static func pair(_ number: Int?, _ total: Int?) -> String {
        guard let number else { return "" }
        return total.map { "\(number)/\($0)" } ?? "\(number)"
    }
}
