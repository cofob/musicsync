import Foundation

/// The video of a song: a video on the server, or one on YouTube. `embed`: the player page of the Invidious or
/// Piped instance that found it, tried before YouTube's own.
public enum MusicVideo: Codable, Hashable, Sendable {
    case server(id: String)
    case youtube(id: String, embed: URL? = nil)

    /// The server video whose title holds the song's title, and its artist when the video names one.
    public static func match(_ song: Song, in videos: [Song]) -> Song? {
        let title = fold(song.title), artist = song.artist.map(fold)
        return videos.first { video in
            let name = fold(video.title)
            guard name.contains(title) else { return false }
            guard let artist else { return true }
            return name.contains(artist) || video.artist.map(fold) == artist || video.artist == nil
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}

public extension SubsonicClient {
    /// The server's videos; none when the server has no videos (Navidrome) or does not know the call.
    func videos() async -> [Song] {
        struct Videos: Decodable, Sendable { let video: [Song]? }
        let reply: Videos? = try? await request("getVideos", key: "videos")
        return reply?.video ?? []
    }
}

/// Finds a song's video on YouTube with the search of an Invidious or Piped instance that fastsi.de picks from
/// the ones online. Sends only the artist and title of one song, and only to the instance.
public struct MusicVideoFinder: Sendable {
    let session: URLSession
    let fastside: URL

    /// Without cookies or a cache.
    public init(session: URLSession = URLSession(configuration: .ephemeral), fastside: URL = URL(string: "https://fastsi.de")!) {
        self.session = session
        self.fastside = fastside
    }

    /// The video, with the embed page of the instance that found it when the instance can play it; nil when the
    /// search finds no video of the song. Invidious first, else Piped; throws when neither answers.
    public func video(artist: String, title: String) async throws -> MusicVideo? {
        let query = "\(artist) \(title) official video"
        let found = try await { do { return try await invidious(query) } catch { return try await piped(query) } }()
        guard let id = Self.pick(found.hits, artist: artist, title: title) else { return nil }
        let playable = (try? await get(URLRequest(url: found.streams(id)))) != nil
        return .youtube(id: id, embed: playable ? found.root.appendingPathComponent("embed/\(id)") : nil)
    }

    /// A search: its videos, the instance's root (for its embed page) and the address of a video's streams.
    struct Search { let hits: [Hit]; let root: URL; let streams: (String) -> URL }

    /// A search result: video id, title, channel.
    public typealias Hit = (id: String, title: String, author: String)

    /// fastside's `/api/v1/redirect` gives an Invidious instance for a YouTube link.
    private func invidious(_ query: String) async throws -> Search {
        var pick = URLRequest(url: fastside.appendingPathComponent("api/v1/redirect"))
        pick.httpMethod = "POST"
        pick.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pick.httpBody = Data(#"{"url":"https://www.youtube.com/","config":\#(Self.config)}"#.utf8)
        let instance = try Self.decodeRedirect(await get(pick).data)
        var search = URLComponents(url: instance.appendingPathComponent("api/v1/search"), resolvingAgainstBaseURL: false)!
        search.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "video")]
        return Search(hits: try Self.decodeInvidious(await get(URLRequest(url: search.url!)).data), root: instance,
                      streams: { instance.appendingPathComponent("api/v1/videos/\($0)") })
    }

    /// Piped has no link rules in fastside, so `/piped/` redirects to a frontend; its API host is the default
    /// `instance` in the frontend's `useApi` script (index page → index script → that chunk).
    private func piped(_ query: String) async throws -> Search {
        var pick = URLRequest(url: fastside.appendingPathComponent("piped/"))
        pick.setValue("config=" + Data(Self.config.utf8).base64EncodedString(), forHTTPHeaderField: "Cookie")
        let (page, frontend) = try await get(pick)
        func asset(_ text: Data, _ regex: Regex<(Substring, Substring)>) throws -> URL {
            guard let path = String(decoding: text, as: UTF8.self).firstMatch(of: regex)?.1 else { throw SubsonicError.badResponse("no Piped API") }
            return URL(string: "/assets/" + path, relativeTo: frontend)!.absoluteURL
        }
        let index = try await get(URLRequest(url: asset(page, /\/assets\/(index-[\w-]+\.js)/))).data
        let chunk = try await get(URLRequest(url: asset(index, /assets\/(useApi-[\w-]+\.js)/))).data
        let api = try Self.pipedAPI(chunk)
        var search = URLComponents(url: api.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        search.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "filter", value: "videos")]
        return Search(hits: try Self.decodePiped(await get(URLRequest(url: search.url!)).data), root: URL(string: "/", relativeTo: frontend)!.absoluteURL,
                      streams: { api.appendingPathComponent("streams/\($0)") })
    }

    /// A random online instance over HTTPS, without bot checks (they block the API).
    static let config = #"{"select_method":"Random","required_tags":["clearnet","https"],"forbidden_tags":["antibot"]}"#

    /// The body and the URL after redirects.
    private func get(_ request: URLRequest) async throws -> (data: Data, url: URL) {
        var request = request
        request.timeoutInterval = 15
        request.setValue(LRCLIBClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let url = response.url else { throw SubsonicError.badStatus(status) }
        return (data, url)
    }

    /// The instance's root in a fastside redirect reply; throws for the fallback (YouTube itself: none is online).
    public static func decodeRedirect(_ data: Data) throws -> URL {
        struct Reply: Decodable { let url: URL; let is_fallback: Bool? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.is_fallback != true, var root = URLComponents(url: reply.url, resolvingAgainstBaseURL: false) else {
            throw SubsonicError.badResponse("no Invidious instance online")
        }
        root.path = "/"
        root.query = nil
        return root.url!
    }

    /// The default API host in a Piped frontend script: ``instance`,`https://…` ``.
    public static func pipedAPI(_ script: Data) throws -> URL {
        guard let host = String(decoding: script, as: UTF8.self).firstMatch(of: /`instance`,\s*`(https:\/\/[^`]+)`/)?.1,
              let url = URL(string: String(host)) else { throw SubsonicError.badResponse("no Piped API") }
        return url
    }

    /// Videos in an Invidious `/api/v1/search` reply.
    public static func decodeInvidious(_ data: Data) throws -> [Hit] {
        struct Item: Decodable { let type: String?; let videoId: String?; let title: String?; let author: String? }
        return try JSONDecoder().decode([Item].self, from: data).compactMap {
            guard $0.type == "video", let id = $0.videoId, let title = $0.title else { return nil }
            return (id, title, $0.author ?? "")
        }
    }

    /// Videos in a Piped `/search` reply (`url` is `/watch?v=…`).
    public static func decodePiped(_ data: Data) throws -> [Hit] {
        struct Reply: Decodable { let items: [Item]? }
        struct Item: Decodable { let type: String?; let url: String?; let title: String?; let uploaderName: String? }
        return try JSONDecoder().decode(Reply.self, from: data).items?.compactMap {
            guard $0.type == "stream", let title = $0.title,
                  let id = $0.url.flatMap({ URLComponents(string: $0)?.queryItems?.first { $0.name == "v" }?.value }) else { return nil }
            return (id, title, $0.uploaderName ?? "")
        } ?? []
    }

    /// The first video whose title holds the song's title, from the artist (in its title or channel); not the
    /// audio-only "Artist - Topic" uploads.
    public static func pick(_ hits: [Hit], artist: String, title: String) -> String? {
        let a = MusicVideo.fold(artist), t = MusicVideo.fold(title)
        return hits.first {
            let name = MusicVideo.fold($0.title), author = MusicVideo.fold($0.author)
            return name.contains(t) && !author.hasSuffix(" - topic") && (name.contains(a) || author.contains(a))
        }?.id
    }
}

/// Blocks YouTube ads in the embedded player: a content rule list for ad and tracking requests, and a script that
/// skips the ads that come from the same hosts as the video.
public enum YouTubeAdBlock {
    /// Ad and tracking URLs (regular expressions of WebKit content rules).
    public static let blocked = [
        "^https?://([^/]+\\.)?doubleclick\\.net/",
        "^https?://([^/]+\\.)?googlesyndication\\.com/",
        "^https?://([^/]+\\.)?googleadservices\\.com/",
        "^https?://([^/]+\\.)?google-analytics\\.com/",
        "^https?://([^/]+\\.)?youtube(-nocookie)?\\.com/api/stats/",
        "^https?://([^/]+\\.)?youtube(-nocookie)?\\.com/pagead/",
        "^https?://([^/]+\\.)?youtube(-nocookie)?\\.com/ptracking",
        "^https?://([^/]+\\.)?youtube(-nocookie)?\\.com/get_midroll_",
        "^https?://([^/]+\\.)?youtube(-nocookie)?\\.com/youtubei/v1/log_event",
        "^https?://[^/]+\\.googlevideo\\.com/.*[?&]ctier=L",
    ]

    /// The rules as WebKit's content blocker JSON.
    public static var rules: String {
        let list = blocked.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: list), as: UTF8.self)
    }

    /// While the player shows an ad: mute it, jump to its end, press Skip, hide overlay ads.
    public static let script = """
        (() => {
          const skip = () => {
            document.querySelectorAll('.ytp-ad-overlay-container, .ytp-ad-module .ytp-ad-image-overlay').forEach(e => e.style.display = 'none');
            const player = document.querySelector('.html5-video-player');
            const video = player && player.querySelector('video');
            if (!player || !player.classList.contains('ad-showing')) {
              if (video && window.adMuted) { video.muted = false; window.adMuted = false; }  // the ad's mute, not the user's
              return;
            }
            if (video) {
              if (!video.muted) { video.muted = true; window.adMuted = true; }
              if (isFinite(video.duration)) video.currentTime = video.duration;
            }
            document.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button').forEach(b => b.click());
          };
          new MutationObserver(skip).observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['class'], childList: true });
          setInterval(skip, 500);
        })();
        """
}
