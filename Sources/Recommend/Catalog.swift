import Foundation

/// Everything the recommender knows (library, playlists, local history, server hints), indexed for quick lookups.
/// Build it off the main thread. Results depend only on the inputs and the random seed.
public struct Catalog: Sendable {
    /// Songs listed together: a playlist or a listening session. Big groups say less, so they weigh less.
    struct Group: Sendable {
        let members: [String]
        let weight: Double
    }

    public let tracks: [String: Track]
    /// Track ids in a fixed order, so no result depends on dictionary order.
    let ids: [String]
    let stats: [String: SongStats]
    let now: Date
    let byArtist: [String: [String]]
    let byAlbum: [String: [String]]
    let byGenre: [String: [String]]
    /// Display name per genre key: its most common spelling.
    let genreNames: [String: String]
    let playlists: [Group]
    let sessions: [Group]
    let playlistsOf: [String: [Int]]
    let sessionsOf: [String: [Int]]
    private(set) var similar: [String: Set<String>]
    /// Played in the last two days; radio and mixes pick them only when nothing else fits.
    let recent: Set<String>
    /// Completed plays in the last 30 days.
    let recentPlays: [String: Int]
    /// Completed plays, newest first, each song once.
    let lastListened: [String]
    let maxPlays: Int
    /// At most this many plays is "rarely played": the least played tenth of the library, and at least 1.
    let rarePlays: Int
    /// Played in the last 12 hours, skips included; mixes put them last.
    let justHeard: Set<String>
    let feedback: Feedback
    let context: ListeningContext

    /// `playlists`: song ids of each playlist. `similar`: server similar songs by song id.
    /// `dislikes`: songs marked "Not for Me". `calendar` gives the part of the day and the weekend.
    public init(tracks list: [Track], playlists: [[String]] = [], history: [PlayEvent] = [], stats: [String: SongStats] = [:],
                similar: [String: [String]] = [:], dislikes: Set<String> = [], now: Date = Date(), calendar: Calendar = .current) {
        var tracks: [String: Track] = [:]
        for track in list { tracks[track.id] = track }
        self.tracks = tracks
        ids = tracks.keys.sorted()
        self.stats = stats
        self.now = now
        var byArtist: [String: [String]] = [:], byAlbum: [String: [String]] = [:], byGenre: [String: [String]] = [:]
        var spellings: [String: Int] = [:]
        for id in ids {
            guard let t = tracks[id] else { continue }
            for key in t.artistKeys { byArtist[key, default: []].append(id) }
            if let album = t.albumId { byAlbum[album, default: []].append(id) }
            for genre in t.genres { byGenre[genre, default: []].append(id) }
            for name in t.genreNames { spellings[name, default: 0] += 1 }
        }
        genreNames = GenreName.displayNames(spellings)
        self.byArtist = byArtist
        self.byAlbum = byAlbum
        self.byGenre = byGenre
        self.playlists = playlists.map { Group(members: $0.filter { tracks[$0] != nil }, weight: Self.weight(size: $0.count)) }
        let events = history.filter { tracks[$0.songId] != nil }.sorted { $0.startedAt < $1.startedAt }
        sessions = Self.sessions(events)
        playlistsOf = Self.membership(self.playlists)
        sessionsOf = Self.membership(sessions)
        self.similar = similar.mapValues(Set.init)
        recent = Set(events.filter { now.timeIntervalSince($0.startedAt) < 2 * 86400 }.map(\.songId))
        recentPlays = events.filter { $0.completed && now.timeIntervalSince($0.startedAt) < 30 * 86400 }
            .reduce(into: [:]) { $0[$1.songId, default: 0] += 1 }
        var seen = Set<String>()
        lastListened = events.reversed().filter(\.completed).map(\.songId).filter { seen.insert($0).inserted }
        maxPlays = tracks.values.map { max($0.serverPlays, stats[$0.id]?.plays ?? 0) }.max() ?? 0
        rarePlays = max(1, Self.quantile(tracks.values.map { max($0.serverPlays, stats[$0.id]?.plays ?? 0) }, 0.1))
        justHeard = Set(events.filter { now.timeIntervalSince($0.startedAt) < 12 * 3600 }.map(\.songId))
        feedback = Feedback(events, tracks: tracks, dislikes: dislikes, now: now)
        context = ListeningContext(events, now: now, calendar: calendar)
    }

    /// The same catalog with more server similar songs (fetched for a station seed).
    public func adding(similar more: [String: [String]]) -> Catalog {
        var copy = self
        for (id, list) in more { copy.similar[id, default: []].formUnion(list) }
        return copy
    }

    /// The value `share` of the way up the sorted `values`; 0 for none.
    static func quantile(_ values: [Int], _ share: Double) -> Int {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * share)]
    }

    /// 1 for up to 20 songs, then less: a 40-song playlist 0.5, an 80-song one 0.33.
    static func weight(size: Int) -> Double { 1 / (1 + log2(max(1, Double(size) / 20))) }

    /// Completed plays split where the listener paused for more than 20 minutes; at most 50 songs each.
    static func sessions(_ events: [PlayEvent]) -> [Group] {
        var groups: [Group] = [], current: [PlayEvent] = []
        func close() {
            let ids = current.filter(\.completed).map(\.songId)
            // Songs the app picked itself (mixes, radio) are weaker evidence that they belong together.
            let chosen = current.allSatisfy { $0.source == .mix || $0.source == .radio } ? 0.5 : 1
            if Set(ids).count > 1 { groups.append(Group(members: ids, weight: chosen)) }
            current = []
        }
        for event in events {
            if let last = current.last, event.startedAt.timeIntervalSince(last.startedAt) - last.played > 20 * 60 || current.count >= 50 { close() }
            current.append(event)
        }
        close()
        return groups
    }

    static func membership(_ groups: [Group]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for (i, group) in groups.enumerated() { for id in Set(group.members) { out[id, default: []].append(i) } }
        return out.mapValues { $0.sorted() }
    }

    // MARK: Scores

    /// How much the listener likes a track: stars, rating, plays and full listens raise it; skips, early stops and
    /// "Not for Me" lower it, a little also for the other songs of the artist.
    func affinity(_ id: String) -> Double {
        guard let t = tracks[id] else { return 0 }
        let s = stats[id]
        var a = t.starred ? 0.35 : 0
        if t.rating > 0 { a += Double(t.rating - 3) * 0.12 }
        let plays = max(t.serverPlays, s?.plays ?? 0)
        if maxPlays > 0 { a += 0.3 * log1p(Double(plays)) / log1p(Double(maxPlays)) }
        if let s { a -= 0.5 * s.skipRatio + (s.plays > 0 ? 0.2 * (1 - s.completion) : 0) }
        return a + 0.3 * feedback.song(id) + 0.15 * feedback.artist(Track.key(t.artist))
    }

    /// Track-to-track similarity, about 0...2. Shared playlists and sessions weigh most.
    func similarity(_ a: String, _ b: String) -> Double {
        guard a != b, let x = tracks[a], let y = tracks[b] else { return 0 }
        var s = 0.0
        if !x.artistKeys.isDisjoint(with: y.artistKeys) { s += 0.3 }
        if let album = x.albumId, album == y.albumId { s += 0.2 }
        if !x.genres.isEmpty, !y.genres.isEmpty {
            let shared = Set(x.genres).intersection(y.genres).count
            s += 0.3 * Double(shared) / Double(Set(x.genres).union(y.genres).count)
        }
        if let p = x.year, let q = y.year { s += 0.1 * max(0, 1 - Double(abs(p - q)) / 10) }
        s += 0.8 * min(1, overlap(playlistsOf[a], playlistsOf[b], playlists))
        s += 0.5 * min(1, overlap(sessionsOf[a], sessionsOf[b], sessions) / 2)
        if similar[a]?.contains(b) == true || similar[b]?.contains(a) == true { s += 0.5 }
        return s
    }

    /// In one playlist or listening session, or similar by the server.
    func together(_ a: String, _ b: String) -> Bool {
        overlap(playlistsOf[a], playlistsOf[b], playlists) > 0 || overlap(sessionsOf[a], sessionsOf[b], sessions) > 0
            || similar[a]?.contains(b) == true || similar[b]?.contains(a) == true
    }

    private func overlap(_ a: [Int]?, _ b: [Int]?, _ groups: [Group]) -> Double {
        guard let a, let b else { return 0 }
        let set = Set(a)
        return b.filter(set.contains).reduce(0) { $0 + groups[$1].weight }
    }

    /// Tracks worth scoring next to `id`: its album, artist, playlists, sessions, server picks and a sample of its genres.
    func neighbors(_ id: String, _ rng: inout SeededRandom) -> [String] {
        guard let t = tracks[id] else { return [] }
        var out = t.albumId.flatMap { byAlbum[$0] } ?? []
        for key in t.artistKeys.sorted() { out += (byArtist[key] ?? []).prefix(300) }
        for genre in t.genres { out += sample(byGenre[genre] ?? [], 150, &rng) }
        for p in playlistsOf[id] ?? [] where playlists[p].members.count <= 500 { out += playlists[p].members }
        for s in sessionsOf[id] ?? [] { out += sessions[s].members }
        out += (similar[id] ?? []).filter { tracks[$0] != nil }.sorted()
        return out
    }

    func sample(_ ids: [String], _ count: Int, _ rng: inout SeededRandom) -> [String] {
        guard ids.count > count else { return ids }
        var copy = ids
        for i in 0..<count { copy.swapAt(i, i + Int(rng.next() % UInt64(copy.count - i))) }
        return Array(copy.prefix(count))
    }

    /// Local plays when known, else the server count.
    func plays(_ id: String) -> Int { max(tracks[id]?.serverPlays ?? 0, stats[id]?.plays ?? 0) }

    /// Local last play, else the server hint.
    func lastPlayed(_ id: String) -> Date? { stats[id]?.lastPlayed ?? tracks[id]?.lastPlayed }

    // MARK: Spacing

    /// No three in a row by one artist and no two in a row from one album.
    public func fits(_ id: String, after list: [String]) -> Bool {
        guard let t = tracks[id], let last = list.last.flatMap({ tracks[$0] }) else { return true }
        if let album = t.albumId, album == last.albumId { return false }
        guard list.count >= 2, let before = tracks[list[list.count - 2]] else { return true }
        return t.artistKeys.isDisjoint(with: last.artistKeys) || t.artistKeys.isDisjoint(with: before.artistKeys)
            || last.artistKeys.isDisjoint(with: before.artistKeys)
    }

    /// `ids` with the songs over the caps of a list of `size` (`Caps`) moved to the end, so they come only when
    /// nothing else is left; `strict` leaves them out.
    func capped(_ ids: [String], size: Int, strict: Bool = false) -> [String] {
        var caps = Caps(self, size), within: [String] = [], over: [String] = []
        for id in ids {
            if caps.allows(id) { caps.add(id); within.append(id) } else { over.append(id) }
        }
        return strict ? within : within + over
    }

    /// The first `limit` songs of `ids`, skipping ahead past songs that would break the spacing rule or, with a
    /// `limit`, the artist and album caps (`Caps`). When none of the next 30 fits, the next song is taken anyway;
    /// callers pass spare songs to avoid that.
    public func spaced(_ ids: [String], limit: Int? = nil) -> [String] {
        var rest = limit.map { Array(ids.prefix($0 * 3)) } ?? ids, out: [String] = []
        var caps = Caps(self, limit ?? .max / 5)
        while !rest.isEmpty, out.count < limit ?? .max {
            let window = rest.prefix(30)
            let i = window.firstIndex { fits($0, after: out) && caps.allows($0) } ?? window.firstIndex { fits($0, after: out) } ?? rest.startIndex
            caps.add(rest[i])
            out.append(rest.remove(at: i))
        }
        return out
    }
}

/// Songs per artist and per album in a list being built. A list of `size` takes at most `max(3, size / 5)` songs
/// of one artist and `max(2, size / 10)` of one album: 10 and 5 of 50, 3 and 2 of 15.
struct Caps {
    let catalog: Catalog
    let artistCap: Int, albumCap: Int
    private var artists: [String: Int] = [:], albums: [String: Int] = [:]

    init(_ catalog: Catalog, _ size: Int) {
        self.catalog = catalog
        artistCap = max(3, size / 5)
        albumCap = max(2, size / 10)
    }

    func allows(_ id: String) -> Bool {
        guard let t = catalog.tracks[id] else { return true }
        return artists[Track.key(t.artist), default: 0] < artistCap && t.albumId.map { albums[$0, default: 0] < albumCap } ?? true
    }

    mutating func add(_ id: String) {
        guard let t = catalog.tracks[id] else { return }
        if !t.artist.isEmpty { artists[Track.key(t.artist), default: 0] += 1 }
        if let album = t.albumId { albums[album, default: 0] += 1 }
    }
}
