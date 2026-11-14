import Foundation

public extension Catalog {
    /// The part of the day the catalog was made for.
    var dayPart: DayPart { context.part }

    /// "Top Picks": albums the listener plays at this part of the day (more on the same kind of day), the more played
    /// ones more often first; the day and the part of the day seed the order. Empty with fewer than four such albums.
    func topPicks(day: String, limit: Int = 20) -> [String] {
        var score: [String: Double] = [:]
        for (id, hits) in context.inPart where !feedback.rejected.contains(id) {
            if let album = tracks[id]?.albumId { score[album, default: 0] += Double(hits) + 0.5 * Double(context.onDay[id] ?? 0) }
        }
        var rng = SeededRandom("\(day)|\(context.part)|picks")
        let albums = rng.weightedShuffle(score.keys.sorted()) { score[$0] ?? 0 }.prefix(limit)
        return albums.count < 4 ? [] : Array(albums)
    }

    /// "Discover": albums among the least played quarter (at most one play when most are unplayed) and not played
    /// this month, by the artists and in the genres the listener plays and stars most, at most two per artist; the day
    /// seeds the order. Empty with fewer than four such albums.
    func discover(day: String, limit: Int = 20) -> [String] {
        var genres: [String: Double] = [:], artists: [String: Double] = [:]
        for id in ids {
            guard let t = tracks[id] else { continue }
            let w = Double(min(plays(id), 50)) + (t.starred ? 3 : 0)
            guard w > 0 else { continue }
            for genre in t.genres { genres[genre, default: 0] += w }
            if !t.artist.isEmpty { artists[Track.key(t.artist), default: 0] += w }
        }
        let topGenre = genres.values.max() ?? 0, topArtist = artists.values.max() ?? 0
        guard topGenre > 0 || topArtist > 0 else { return [] }
        func taste(_ t: Track) -> Double {
            let genre = topGenre > 0 ? (t.genres.map { genres[$0] ?? 0 }.max() ?? 0) / topGenre : 0
            return 0.5 * genre + (topArtist > 0 ? (artists[Track.key(t.artist)] ?? 0) / topArtist : 0)
        }
        let totals = byAlbum.mapValues { $0.reduce(0) { $0 + plays($1) } }
        let rare = max(1, Self.quantile(Array(totals.values), 0.25))
        let candidates: [(album: String, artist: String, taste: Double)] = byAlbum.keys.sorted().compactMap { album in
            let songs = byAlbum[album] ?? []
            guard let t = songs.first.flatMap({ tracks[$0] }), totals[album] ?? 0 <= rare,
                  !songs.contains(where: { feedback.rejected.contains($0) || recentPlays[$0] != nil }) else { return nil }
            let w = taste(t)
            return w > 0 ? (album, Track.key(t.artist), w) : nil
        }
        var rng = SeededRandom("\(day)|discover"), perArtist: [String: Int] = [:], out: [String] = []
        for c in rng.weightedShuffle(candidates, weight: \.taste) where out.count < limit {
            perArtist[c.artist, default: 0] += 1
            if perArtist[c.artist, default: 0] <= 2 { out.append(c.album) }
        }
        return out.count < 4 ? [] : out
    }

    /// Why a station holds its songs, for its subtitle: "More by Artist · Rock · 1990s", "Similar artists · Jazz".
    /// A part counts when enough of `picks` share it with a seed; `timeOfDay` adds "Often Played in the Evening"
    /// when the picks are mostly songs played at this time.
    func reason(seeds: [String], picks: [String], timeOfDay: Bool = false) -> String {
        let seeds = seeds.compactMap { tracks[$0] }, songs = picks.compactMap { tracks[$0] }
        guard let first = seeds.first, !songs.isEmpty else { return "" }
        func share(_ test: (Track, Track) -> Bool) -> Double {
            Double(songs.filter { song in seeds.contains { test($0, song) } }.count) / Double(songs.count)
        }
        let sameArtist = { (a: Track, b: Track) in !a.artistKeys.isDisjoint(with: b.artistKeys) }
        var parts: [String] = []
        if !first.artist.isEmpty, share(sameArtist) >= 0.3 { parts.append("More by \(first.artist)") }
        if share({ !sameArtist($0, $1) && together($0.id, $1.id) }) >= 0.25 { parts.append("Similar artists") }
        let seedGenres = Set(seeds.flatMap(\.genres))
        let shared = Dictionary(grouping: songs.flatMap { $0.genres.filter(seedGenres.contains) }, by: { $0 }).mapValues(\.count)
        if let genre = shared.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), Double(genre.value) >= 0.5 * Double(songs.count) {
            parts.append(genreNames[genre.key] ?? genre.key)
        }
        if let year = first.year, share({ a, b in a.year.flatMap { x in b.year.map { abs(x - $0) <= 5 } } ?? false }) >= 0.5 {
            parts.append("\(year / 10 * 10)s")
        }
        if timeOfDay, songs.filter({ context.score($0.id) >= 0.5 }).count * 2 >= songs.count {
            parts.append("Often Played \(context.part.phrase)")
        }
        return parts.isEmpty ? "Songs like this one" : parts.prefix(3).joined(separator: " · ")
    }
}
