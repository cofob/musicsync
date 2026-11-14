import Foundation

public extension Catalog {
    /// A station: starts close to the seeds and drifts, each pick similar to the one before it.
    /// `exclude` (e.g. the current queue) is never picked; recently played tracks only when nothing else fits.
    /// `includeSeed` starts with the first seed.
    func radio(seeds: [String], count: Int, seed: UInt64, exclude: Set<String> = [], includeSeed: Bool = true) -> [String] {
        let seeds = seeds.filter { tracks[$0] != nil }
        guard let last = seeds.last, count > 0 else { return [] }
        var rng = SeededRandom(seed: seed)
        var picked = includeSeed ? [seeds[0]] : []
        var used = exclude.union(picked)
        var anchor = picked.last ?? last
        var seedScore: [String: Double] = [:]
        let anchors = Array(seeds.prefix(10))
        while picked.count < count {
            let drift = min(0.7, Double(picked.count) / Double(count))
            let other = seeds[Int(rng.next() % UInt64(seeds.count))]
            let pool = Array(Set(neighbors(anchor, &rng) + neighbors(other, &rng))).sorted().filter { !used.contains($0) }
            func score(_ id: String) -> Double {
                let near = seedScore[id] ?? anchors.map { similarity($0, id) }.max() ?? 0
                seedScore[id] = near
                return (1 - drift) * near + drift * similarity(anchor, id) + 0.35 * affinity(id)
            }
            let fresh = pool.filter { !recent.contains($0) && fits($0, after: picked) }
            let next = choose(fresh, score, &rng)
                ?? choose(pool.filter { fits($0, after: picked) }, score, &rng)
                ?? choose(sample(ids, 300, &rng).filter { !used.contains($0) && fits($0, after: picked) }, affinity, &rng)
            guard let next else { break }
            picked.append(next)
            used.insert(next)
            anchor = next
        }
        return picked
    }

    /// AutoPlay: more of the same after the queue; never a track already in it.
    func continuation(of queue: [String], count: Int = 25, seed: UInt64) -> [String] {
        radio(seeds: Array(queue.suffix(5)), count: count, seed: seed, exclude: Set(queue), includeSeed: false)
    }

    /// Station seeds from many songs (an album, artist or playlist): the ones the listener likes most.
    func seeds(_ ids: [String], limit: Int = 10) -> [String] {
        let scored: [(id: String, score: Double)] = ids.filter { tracks[$0] != nil }.map { ($0, affinity($0)) }
        let best = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        return best.prefix(limit).map(\.id)
    }

    func songs(albumId: String) -> [String] { byAlbum[albumId] ?? [] }
    func songs(artist: String) -> [String] { byArtist[Track.key(artist)] ?? [] }

    /// One of the six best, the better ones more often.
    private func choose(_ ids: [String], _ score: (String) -> Double, _ rng: inout SeededRandom) -> String? {
        let top = ids.map { ($0, score($0)) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(6)
        guard let low = top.last?.1 else { return nil }
        return rng.weightedShuffle(Array(top)) { $0.1 - low + 0.05 }.first?.0
    }
}

/// When AutoPlay adds songs.
public enum AutoPlay {
    /// At most one song is left and the queue would stop (repeat off).
    public static func shouldExtend(remaining: Int, enabled: Bool, repeating: Bool) -> Bool {
        enabled && !repeating && remaining <= 1
    }
}
