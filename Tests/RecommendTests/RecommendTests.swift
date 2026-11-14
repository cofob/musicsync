import Foundation
import Testing
@testable import Recommend

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day = 86400.0

/// 6 artists × 3 albums × 8 songs. Artists 0–2 play rock, 3–5 jazz. Ids look like "a1-b2-3".
private func library(starred: Set<String> = [], plays: [String: Int] = [:], rating: [String: Int] = [:],
                     created: (String) -> Date? = { _ in now.addingTimeInterval(-400 * day) }) -> [Track] {
    (0..<6).flatMap { a in (0..<3).flatMap { b in (0..<8).map { n in
        let id = "a\(a)-b\(b)-\(n)"
        return Track(id: id, title: "Song \(id)", artist: "Artist \(a)", albumId: "a\(a)-b\(b)", genre: a < 3 ? "Rock" : "Jazz",
                     year: 1990 + a * 5 + b, duration: 200, starred: starred.contains(id), rating: rating[id] ?? 0,
                     serverPlays: plays[id] ?? 0, created: created(id))
    } } }
}

private func play(_ id: String, _ ago: Double, played: Double = 200, source: PlaySource = .album) -> PlayEvent {
    PlayEvent(songId: id, startedAt: now.addingTimeInterval(-ago), played: played, duration: 200, source: source)
}

private func artist(_ id: String) -> String { String(id.prefix(2)) }
private func album(_ id: String) -> String { String(id.prefix(5)) }

/// Fails when three songs in a row share an artist or two in a row share an album.
private func isSpaced(_ ids: [String]) -> Bool {
    for i in ids.indices.dropFirst() where album(ids[i]) == album(ids[i - 1]) { return false }
    for i in ids.indices.dropFirst(2) where Set(ids[i - 2...i].map(artist)).count == 1 { return false }
    return true
}

@Suite struct TrackTests {
    @Test func genresAndArtists() {
        let t = Track(id: "1", title: "T", artist: "Björk ", albumArtist: "björk", genre: "Rock; Pop/rock,Indie")
        #expect(t.genres == ["rock", "pop", "indie"])
        #expect(t.artistKeys == ["björk"])
        #expect(Track(id: "2", title: "T", artist: nil).artistKeys.isEmpty)
    }

    @Test func completionFollowsTheScrobbleRule() {
        #expect(PlayEvent(songId: "s", startedAt: now, played: 100, duration: 200).completed)
        #expect(PlayEvent(songId: "s", startedAt: now, played: 99, duration: 200).skipped)
        #expect(PlayEvent(songId: "s", startedAt: now, played: 240, duration: 900).completed)
        #expect(PlayEvent(songId: "s", startedAt: now, played: 50, duration: 0).skipped)
    }

    @Test func seededRandomIsStable() {
        var a = SeededRandom("2026-11-14|x"), b = SeededRandom("2026-11-14|x"), c = SeededRandom("2026-11-15|x")
        let x = (0..<5).map { _ in a.next() }
        #expect(x == (0..<5).map { _ in b.next() })
        #expect(x != (0..<5).map { _ in c.next() })
    }
}

@Suite struct SimilarityTests {
    @Test func signalsAddUp() {
        let tracks = library()
        let plain = Catalog(tracks: tracks, now: now)
        #expect(plain.similarity("a0-b0-0", "a0-b0-1") > plain.similarity("a0-b0-0", "a0-b1-0"))  // same album
        #expect(plain.similarity("a0-b0-0", "a0-b1-0") > plain.similarity("a0-b0-0", "a1-b0-0"))  // same artist
        #expect(plain.similarity("a0-b0-0", "a1-b0-0") > plain.similarity("a0-b0-0", "a5-b0-0"))  // same genre, closer years
        #expect(plain.similarity("a0-b0-0", "a0-b0-0") == 0)

        let base = plain.similarity("a0-b0-0", "a5-b2-7")
        let listed = Catalog(tracks: tracks, playlists: [["a0-b0-0", "a5-b2-7"]], now: now)
        let heard = Catalog(tracks: tracks, history: [play("a0-b0-0", 1000), play("a5-b2-7", 700)], now: now)
        let server = Catalog(tracks: tracks, similar: ["a0-b0-0": ["a5-b2-7"]], now: now)
        #expect(listed.similarity("a0-b0-0", "a5-b2-7") >= base + 0.8)
        #expect(heard.similarity("a5-b2-7", "a0-b0-0") > base)
        #expect(server.similarity("a5-b2-7", "a0-b0-0") >= base + 0.5)
        // Plays far apart are separate sessions; a big playlist counts less than a small one.
        let apart = Catalog(tracks: tracks, history: [play("a0-b0-0", 10 * day), play("a5-b2-7", day)], now: now)
        #expect(apart.similarity("a0-b0-0", "a5-b2-7") == base)
        let big = Catalog(tracks: tracks, playlists: [["a0-b0-0", "a5-b2-7"] + tracks.prefix(78).map(\.id)], now: now)
        #expect(big.similarity("a0-b0-0", "a5-b2-7") < listed.similarity("a0-b0-0", "a5-b2-7"))
    }

    @Test func affinityRewardsLoveAndPunishesSkips() {
        let tracks = library(starred: ["a0-b0-0"], plays: ["a0-b0-1": 20, "a0-b0-2": 20], rating: ["a0-b0-3": 5, "a0-b0-4": 1])
        let skips = ["a0-b0-2": SongStats(plays: 1, skips: 5, lastPlayed: now, completion: 0.3)]
        let catalog = Catalog(tracks: tracks, stats: skips, now: now)
        let plain = catalog.affinity("a1-b0-0")
        #expect(catalog.affinity("a0-b0-0") > plain)
        #expect(catalog.affinity("a0-b0-1") > plain)
        #expect(catalog.affinity("a0-b0-3") > plain && catalog.affinity("a0-b0-4") < plain)
        #expect(catalog.affinity("a0-b0-2") < catalog.affinity("a0-b0-1"))
    }

    @Test func spacingRules() {
        let catalog = Catalog(tracks: library(), now: now)
        #expect(!catalog.fits("a0-b0-1", after: ["a0-b0-0"]))  // same album
        #expect(catalog.fits("a0-b1-0", after: ["a0-b0-0"]))
        #expect(!catalog.fits("a0-b2-0", after: ["a0-b0-0", "a0-b1-0"]))  // third in a row by one artist
        #expect(catalog.fits("a0-b2-0", after: ["a0-b0-0", "a1-b1-0"]))
        let clumped = (0..<8).map { "a0-b0-\($0)" } + (0..<8).map { "a1-b0-\($0)" } + (0..<8).map { "a2-b1-\($0)" }
        let spaced = catalog.spaced(clumped)
        #expect(Set(spaced) == Set(clumped) && spaced.count == clumped.count)
        #expect(isSpaced(catalog.spaced(clumped, limit: 12)))
    }
}

@Suite struct RadioTests {
    @Test func startsAtTheSeedAndKeepsTheRules() {
        let catalog = Catalog(tracks: library(), now: now)
        let list = catalog.radio(seeds: ["a0-b0-0"], count: 30, seed: 7)
        #expect(list.first == "a0-b0-0" && list.count == 30)
        #expect(Set(list).count == list.count)
        #expect(isSpaced(list))
        #expect(list == catalog.radio(seeds: ["a0-b0-0"], count: 30, seed: 7))
        #expect(list != catalog.radio(seeds: ["a0-b0-0"], count: 30, seed: 8))
        // Starts near the seed: the first picks stay in its genre.
        #expect(list.prefix(8).allSatisfy { Int($0.dropFirst().prefix(1))! < 3 })
        #expect(catalog.radio(seeds: ["unknown"], count: 5, seed: 1).isEmpty)
    }

    @Test func avoidsRecentPlaysExcludedAndSkippedSongs() {
        let tracks = library()
        let recent = (0..<8).map { "a1-b0-\($0)" } + (0..<8).map { "a2-b0-\($0)" }
        let catalog = Catalog(tracks: tracks, history: recent.enumerated().map { play($1, Double($0) * 300) }, now: now)
        let list = catalog.radio(seeds: ["a0-b0-0"], count: 20, seed: 3, exclude: ["a0-b1-0", "a0-b1-1"])
        #expect(list.count == 20)
        #expect(Set(list).isDisjoint(with: recent))
        #expect(!list.contains("a0-b1-0") && !list.contains("a0-b1-1"))
    }

    @Test func playlistNeighborsComeEarly() {
        let friends = ["a5-b2-1", "a4-b2-2", "a3-b2-3"]
        let catalog = Catalog(tracks: library(), playlists: [["a0-b0-0"] + friends], now: now)
        let list = catalog.radio(seeds: ["a0-b0-0"], count: 10, seed: 11)
        #expect(friends.filter(list.contains).count >= 2)
    }

    @Test func autoPlayContinuesFromTheQueueEnd() {
        let catalog = Catalog(tracks: library(), now: now)
        let queue = ["a3-b0-0", "a4-b1-0", "a3-b2-0"]
        let more = catalog.continuation(of: queue, count: 15, seed: 5)
        #expect(more.count == 15 && Set(more).isDisjoint(with: queue))
        #expect(more.prefix(5).allSatisfy { Int($0.dropFirst().prefix(1))! >= 3 })  // jazz like the queue
        #expect(AutoPlay.shouldExtend(remaining: 1, enabled: true, repeating: false))
        #expect(AutoPlay.shouldExtend(remaining: 0, enabled: true, repeating: false))
        #expect(!AutoPlay.shouldExtend(remaining: 2, enabled: true, repeating: false))
        #expect(!AutoPlay.shouldExtend(remaining: 0, enabled: false, repeating: false))
        #expect(!AutoPlay.shouldExtend(remaining: 0, enabled: true, repeating: true))
    }
}

@Suite struct MixTests {
    private func kinds(_ mixes: [Mix]) -> [Mix.Kind] { mixes.map(\.kind) }

    /// No local history: stars, ratings, server plays and dates only.
    private var coldStart: Catalog {
        let starred = Set((0..<12).map { "a\($0 % 6)-b0-\($0 % 8)" })
        let plays = Dictionary(uniqueKeysWithValues: (0..<8).flatMap { n in ["a0-b1-\(n)", "a3-b1-\(n)"].map { ($0, 10 + n) } })
        return Catalog(tracks: library(starred: starred, plays: plays) { id in
            id.hasPrefix("a5-b2") ? now.addingTimeInterval(-day) : now.addingTimeInterval(-400 * day)
        }, now: now)
    }

    @Test func coldStartGivesMixes() throws {
        let catalog = coldStart
        let mixes = catalog.madeForYou(day: "2026-11-14", size: 20)
        #expect(kinds(mixes).starts(with: [.favorites, .heavyRotation, .rediscover, .fresh, .deepCuts]))
        #expect(mixes.filter { $0.kind == .daily }.count == 2)  // rock and jazz
        for mix in mixes { #expect(isSpaced(mix.trackIds), "\(mix.id)"); #expect(Set(mix.trackIds).count == mix.trackIds.count) }
        let favorites = try #require(mixes.first { $0.kind == .favorites })
        #expect(favorites.trackIds.allSatisfy { catalog.tracks[$0]?.starred == true })
        let heavy = try #require(mixes.first { $0.kind == .heavyRotation })
        #expect(heavy.trackIds.allSatisfy { $0.contains("-b1-") && ($0.hasPrefix("a0") || $0.hasPrefix("a3")) })
        let fresh = try #require(catalog.madeForYou(day: "2026-11-14", size: 30).first { $0.kind == .fresh })
        #expect(fresh.trackIds.first?.hasPrefix("a5-b2") == true && fresh.trackIds.prefix(16).filter { $0.hasPrefix("a5-b2") }.count == 8)
        let deep = try #require(mixes.first { $0.kind == .deepCuts })
        #expect(deep.trackIds.allSatisfy { ($0.hasPrefix("a0") || $0.hasPrefix("a3")) && !$0.contains("-b1-") })
        #expect(Set(mixes.filter { $0.kind == .daily }.map { $0.subtitle.prefix(7) }) == ["Rock · ", "Jazz · "])
        let because = catalog.becauseYouListened(day: "2026-11-14", shelves: 2, size: 10)
        #expect(because.count == 2 && because.allSatisfy { $0.trackIds.count == 10 && !$0.trackIds.contains($0.seedId ?? "") })
    }

    @Test func mixesAreStableForADay() {
        let catalog = coldStart
        #expect(catalog.madeForYou(day: "2026-11-14") == catalog.madeForYou(day: "2026-11-14"))
        #expect(catalog.madeForYou(day: "2026-11-14") != catalog.madeForYou(day: "2026-11-15"))
        #expect(catalog.becauseYouListened(day: "2026-11-14") == catalog.becauseYouListened(day: "2026-11-14"))
    }

    @Test func historyDrivesHeavyRotationRediscoverAndBecause() throws {
        let starred = Set((0..<8).map { "a2-b2-\($0)" } + ["a4-b0-0"])
        // a4-b0-* played a lot this week, the starred a2-b2-* only long ago.
        let week: [PlayEvent] = (0..<24).map { k in play("a4-b0-\(k / 3)", Double(k) * 3600 + 3 * day) }
        let old: [PlayEvent] = (0..<8).map { n in play("a2-b2-\(n)", 200 * day + Double(n) * 300) }
        let events = week + old + [play("a1-b1-1", 600, source: .radio)]
        let stats = Dictionary(grouping: events, by: \.songId).mapValues { list in
            SongStats(plays: list.count, skips: 0, lastPlayed: list.map(\.startedAt).max(), completion: 1)
        }
        let catalog = Catalog(tracks: library(starred: starred), history: events, stats: stats, now: now)
        let mixes = catalog.madeForYou(day: "d", size: 20)
        let heavy = try #require(mixes.first { $0.kind == .heavyRotation })
        #expect(Set(heavy.trackIds).isSubset(of: Set((0..<8).map { "a4-b0-\($0)" } + ["a1-b1-1"])))
        let rediscover = try #require(mixes.first { $0.kind == .rediscover })
        #expect(rediscover.trackIds.contains { $0.hasPrefix("a2-b2") })
        #expect(!rediscover.trackIds.contains { $0.hasPrefix("a4-b0") || $0 == "a1-b1-1" })  // heard recently
        let because = catalog.becauseYouListened(day: "d", shelves: 2)
        #expect(because.map(\.seedId) == ["a1-b1-1", "a4-b0-0"])
        #expect(because.allSatisfy { !$0.trackIds.contains("a1-b1-1") })
    }
}
