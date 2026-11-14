import Foundation

/// Decoding of the `subsonic-response` envelope. The payload key is passed through `userInfo`.
struct APIError: Decodable {
    let code: Int
    let message: String?
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct Head: Decodable {
    let status: String
    let error: APIError?
    let info: ServerInfo

    private enum Keys: String, CodingKey { case status, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(APIError.self, forKey: .error)
        info = try ServerInfo(from: decoder)
    }
}

struct Reply<Body: Decodable>: Decodable {
    static var bodyKey: CodingUserInfoKey { CodingUserInfoKey(rawValue: "subsonic.bodyKey")! }

    let head: Head
    let body: Body?

    init(from decoder: Decoder) throws {
        let inner = try decoder.container(keyedBy: AnyKey.self).superDecoder(forKey: AnyKey("subsonic-response"))
        head = try Head(from: inner)
        if head.status == "ok", let key = decoder.userInfo[Self.bodyKey] as? String {
            body = try inner.container(keyedBy: AnyKey.self).decode(Body.self, forKey: AnyKey(key))
        } else {
            body = nil
        }
    }
}

struct Empty: Decodable, Sendable {}
struct ArtistsBody: Decodable { let index: [ArtistIndex]? }
struct AlbumListBody: Decodable { let album: [Album]? }
struct PlaylistsBody: Decodable { let playlist: [Playlist]? }
