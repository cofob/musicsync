import Foundation

/// A generated song list.
public struct Mix: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case favorites, heavyRotation, rediscover, fresh, deepCuts, daily, because }

    public let id: String
    public let kind: Kind
    /// For `because`: the seed song's title.
    public let title: String
    /// For `because`: the seed song's artist.
    public let subtitle: String
    public let trackIds: [String]
    /// For `because`: the song the shelf is built from.
    public let seedId: String?
    /// For `because`: why these songs, e.g. "Similar artists · Rock" (`Catalog.reason`).
    public var reason = ""
}

public extension Catalog {
    /// Fewer songs than this and a mix is left out.
    static let minimumMix = 8

    /// "Made for You" mixes. `day` (e.g. "2026-11-14") seeds them, so they stay the same for the whole day.
    func madeForYou(day: String, size: Int = 50) -> [Mix] {
        func rng(_ name: String) -> SeededRandom { SeededRandom("\(day)|\(name)") }
        let fixed: [(Mix.Kind, String, String, [String])] = [
            (.favorites, "Favorites Mix", "Songs you love", favorites(size, rng("favorites"))),
            (.heavyRotation, "Heavy Rotation", "What you play most right now", heavyRotation(size, rng("heavy"))),
            (.rediscover, "Rediscover", "Favorites you have not heard in a while", rediscover(size, rng("rediscover"))),
            (.fresh, "Fresh", "New in your library", fresh(size)),
            (.deepCuts, "Deep Cuts", "Unplayed songs by artists you love", deepCuts(size, rng("deep"))),
        ]
        let mixes = fixed.map { Mix(id: $0.0.rawValue, kind: $0.0, title: $0.1, subtitle: $0.2, trackIds: $0.3, seedId: nil) }
        return (mixes + dailyMixes(size, rng("daily"))).filter { $0.trackIds.count >= Self.minimumMix }
    }

    /// "Because You Listened to" shelves: a short station from each recent play (or a favorite on a new install).
    func becauseYouListened(day: String, shelves: Int = 3, size: Int = 15) -> [Mix] {
        var rng = SeededRandom("\(day)|because")
        var albums = Set<String>()
        let recentSeeds = lastListened.filter { id in !feedback.rejected.contains(id) && tracks[id]?.albumId.map { albums.insert($0).inserted } ?? true }
        let favorites = rng.weightedShuffle(ids.filter { tracks[$0]?.starred == true || plays($0) > 0 }) { affinity($0) + 0.6 }
        let seeds = (recentSeeds.isEmpty ? favorites : recentSeeds).prefix(shelves)
        return seeds.compactMap { id in
            guard let t = tracks[id] else { return nil }
            let list = radio(seeds: [id], count: size, seed: rng.next(), exclude: [id], includeSeed: false)
            return list.count < Self.minimumMix ? nil : Mix(id: "because-\(id)", kind: .because, title: t.title, subtitle: t.artist, trackIds: list,
                                                            seedId: id, reason: reason(seeds: [id], picks: list))
        }
    }

    // MARK: Generators

    private func loved(_ id: String) -> Bool { (tracks[id]?.starred ?? false) || (tracks[id]?.rating ?? 0) >= 4 }

    /// Leaves out rejected songs, puts the ones heard in the last hours last, and keeps the spacing and the artist and
    /// album caps: a shorter mix is better than one artist filling it, but too few songs for a mix take the caps loosely.
    private func finish(_ ids: [String], _ size: Int) -> [String] {
        let kept = ids.filter { !feedback.rejected.contains($0) }
        let ordered = kept.filter { !justHeard.contains($0) } + kept.filter(justHeard.contains)
        let strict = spaced(capped(ordered, size: size, strict: true), limit: size)
        let spacedWell = strict.indices.allSatisfy { fits(strict[$0], after: Array(strict[..<$0])) }
        return strict.count >= Self.minimumMix && spacedWell ? strict : spaced(capped(ordered, size: size), limit: size)
    }

    private func favorites(_ size: Int, _ rng: SeededRandom) -> [String] {
        var rng = rng
        var pool = ids.filter(loved)
        if pool.count < Self.minimumMix {
            pool += ids.filter { !loved($0) && plays($0) > 0 }.sorted { (plays($0), $1) > (plays($1), $0) }.prefix(size * 2)
        }
        return finish(rng.weightedShuffle(pool) { affinity($0) + 0.6 }, size)
    }

    private func heavyRotation(_ size: Int, _ rng: SeededRandom) -> [String] {
        var rng = rng
        let count: (String) -> Int = recentPlays.isEmpty ? { tracks[$0]?.serverPlays ?? 0 } : { recentPlays[$0] ?? 0 }
        let played = ids.filter { count($0) > 0 && !(stats[$0].map { $0.skipRatio > 0.5 } ?? false) }
        let top = capped(played.sorted { (count($0), $1) > (count($1), $0) }, size: size).prefix(size * 2)
        return finish(rng.weightedShuffle(Array(top)) { Double(count($0)) }, size)
    }

    private func rediscover(_ size: Int, _ rng: SeededRandom) -> [String] {
        var rng = rng
        let cutoff = now.addingTimeInterval(-60 * 86400)
        let busy = ids.map(plays).sorted().dropFirst(ids.count * 3 / 4).first ?? 0
        let pool = ids.filter { id in
            (loved(id) || (busy > 0 && plays(id) >= busy)) && !recent.contains(id) && (lastPlayed(id).map { $0 < cutoff } ?? true)
        }
        return finish(rng.weightedShuffle(pool) { id in
            let days = lastPlayed(id).map { now.timeIntervalSince($0) / 86400 } ?? 365
            return affinity(id) + 0.6 + min(days, 365) / 365
        }, size)
    }

    private func fresh(_ size: Int) -> [String] {
        let pool = ids.filter { plays($0) == 0 && tracks[$0]?.created != nil }
        return finish(pool.sorted { (tracks[$0]?.created ?? .distantPast, $1) > (tracks[$1]?.created ?? .distantPast, $0) }, size)
    }

    private func deepCuts(_ size: Int, _ rng: SeededRandom) -> [String] {
        var rng = rng
        var byArtist: [String: Int] = [:]
        for id in ids { if let t = tracks[id], !t.artist.isEmpty { byArtist[Track.key(t.artist), default: 0] += plays(id) } }
        let top = byArtist.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(10).map(\.key)
        let rank = Dictionary(uniqueKeysWithValues: top.enumerated().map { ($1, $0) })
        let pool = ids.filter { id in plays(id) == 0 && !loved(id) && rank[tracks[id].map { Track.key($0.artist) } ?? ""] != nil }
        return finish(rng.weightedShuffle(pool) { id in 1 / Double(1 + (rank[tracks[id].map { Track.key($0.artist) } ?? ""] ?? 10)) }, size)
    }

    /// One mix per favorite genre (up to four): about 60% known songs, 40% songs not played yet.
    private func dailyMixes(_ size: Int, _ rng: SeededRandom) -> [Mix] {
        var rng = rng
        var weight: [String: Double] = [:]
        for id in ids {
            guard let t = tracks[id] else { continue }
            let w = Double(plays(id)) + (t.starred ? 3 : 0) + Double(t.rating)
            for genre in t.genres { weight[genre, default: 0] += w }
        }
        var chosen: [Set<String>] = []
        var mixes: [Mix] = []
        for (genre, w) in weight.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) where w > 0 && mixes.count < 4 {
            let members = byGenre[genre] ?? []
            let set = Set(members)
            // A genre mostly inside an earlier one (e.g. "alt rock" inside "rock") would repeat that mix.
            guard members.count >= 20, !chosen.contains(where: { Double($0.intersection(set).count) > 0.7 * Double(set.count) }) else { continue }
            chosen.append(set)
            // Capped first, so the spare songs taken below do not come mostly from one artist.
            let known = capped(rng.weightedShuffle(members.filter { plays($0) > 0 || loved($0) }) { affinity($0) + 0.6 }, size: size)
            let new = capped(rng.weightedShuffle(members.filter { plays($0) == 0 && !loved($0) }) { _ in 1 }, size: size)
            let room = size * 2  // spare songs, so spacing can skip some
            var list = Array(known.prefix(room * 3 / 5))
            let usedKnown = list.count
            list += new.prefix(room - list.count)
            list += known.dropFirst(usedKnown).prefix(room - list.count)
            let songs = finish(rng.weightedShuffle(list) { _ in 1 }, size)
            var artists: [String: Int] = [:]
            for id in songs { if let a = tracks[id]?.artist, !a.isEmpty { artists[a, default: 0] += 1 } }
            let names = artists.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).map(\.key)
            mixes.append(Mix(id: "daily-\(mixes.count + 1)", kind: .daily, title: "Daily Mix \(mixes.count + 1)",
                             subtitle: ([genreNames[genre] ?? genre] + names).joined(separator: " · "), trackIds: songs, seedId: nil))
        }
        return mixes
    }
}
