import Foundation
import Testing
@testable import Recommend

/// `now` is a Friday, 08:00 UTC: a weekday morning.
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func catalog(_ tracks: [Track] = library(), history: [PlayEvent] = [], dislikes: Set<String> = [], playlists: [[String]] = [],
                     at time: Date = now) -> Catalog {
    Catalog(tracks: tracks, playlists: playlists, history: history, dislikes: dislikes, now: time, calendar: utc)
}

private func counts(_ ids: [String], _ key: (String) -> String) -> [String: Int] {
    Dictionary(grouping: ids, by: key).mapValues(\.count)
}

@Suite struct SkipTests {
    @Test func earlySkipRule() {
        func event(_ played: Double, _ duration: Double) -> PlayEvent { PlayEvent(songId: "s", startedAt: now, played: played, duration: duration) }
        #expect(event(10, 200).earlySkip && event(49, 200).earlySkip && event(20, 0).earlySkip)
        #expect(!event(60, 200).earlySkip && !event(60, 200).completed)  // stopped later: neither
        #expect(!event(100, 200).earlySkip)
        #expect(event(200, 900).earlySkip && !event(230, 900).earlySkip)  // a quarter of a long song
    }

    @Test func skippedSongIsLeftOut() throws {
        let starred = Set((0..<8).map { "a0-b0-\($0)" } + (0..<8).map { "a1-b1-\($0)" })
        let skip = play("a0-b0-3", 2 * day, played: 8)
        let c = catalog(library(starred: starred), history: [skip])
        #expect(c.feedback.rejected == ["a0-b0-3"])
        let favorites = try #require(c.madeForYou(day: "d", size: 15).first { $0.kind == .favorites })
        #expect(favorites.trackIds.count == 15 && !favorites.trackIds.contains("a0-b0-3"))
        #expect(!c.radio(seeds: ["a0-b0-0"], count: 40, seed: 1).contains("a0-b0-3"))
        #expect(!c.continuation(of: ["a0-b0-0", "a0-b0-1"], count: 30, seed: 2).contains("a0-b0-3"))
        // Started on purpose from the skipped song, a station still begins with it.
        #expect(c.radio(seeds: ["a0-b0-3"], count: 5, seed: 1).first == "a0-b0-3")
    }

    @Test func fullListensOutweighOneSkipAndOldSkipsFade() {
        let c = catalog(history: [play("a0-b0-1", 3 * day), play("a0-b0-1", 2 * day), play("a0-b0-1", day, played: 5),
                                  play("a0-b0-2", 40 * day, played: 5)])
        #expect(c.feedback.rejected.isEmpty)
        #expect(c.feedback.song("a0-b0-2") < 0 && c.feedback.song("a0-b0-2") > -0.5)
    }

    @Test func skipsLowerTheArtistALittle() {
        let skips = (0..<5).map { play("a1-b0-\($0)", Double($0 + 1) * day, played: 5) }
        let c = catalog(history: skips + [play("a2-b0-0", day)])
        let plain = c.affinity("a3-b2-7")
        #expect(c.affinity("a1-b2-7") < plain)  // same artist, never skipped
        #expect(c.affinity("a1-b0-0") < c.affinity("a1-b2-7"))  // the skipped song itself, more
        #expect(c.affinity("a2-b0-0") > plain)  // a full listen
    }

    @Test func notForMeIsLeftOutAndRespected() throws {
        let starred = Set((0..<8).map { "a0-b0-\($0)" } + (0..<8).map { "a1-b1-\($0)" })
        let c = catalog(library(starred: starred), dislikes: ["a0-b0-5"])
        #expect(c.feedback.rejected == ["a0-b0-5"])
        #expect(c.affinity("a0-b1-0") < catalog().affinity("a0-b1-0"))
        let favorites = try #require(c.madeForYou(day: "d", size: 15).first { $0.kind == .favorites })
        #expect(!favorites.trackIds.contains("a0-b0-5"))
        #expect(!c.radio(seeds: ["a0-b0-0"], count: 40, seed: 4).contains("a0-b0-5"))
    }
}

@Suite struct DiversityTests {
    @Test func mixesCapArtistsAndAlbums() throws {
        // Artist 0 is played most, so it would fill the mix without the caps.
        let plays = Dictionary(uniqueKeysWithValues: library().map { ($0.id, $0.id.hasPrefix("a0") ? 80 : 1) })
        let c = catalog(library(starred: Set(library().map(\.id)), plays: plays))
        for mix in c.madeForYou(day: "d", size: 20) where mix.kind != .daily {  // a genre here has only three artists
            #expect(counts(mix.trackIds, artist).values.max() ?? 0 <= 4, "\(mix.id)")
            #expect(counts(mix.trackIds, album).values.max() ?? 0 <= 2, "\(mix.id)")
        }
        let favorites = try #require(c.madeForYou(day: "d", size: 20).first { $0.kind == .favorites })
        #expect(favorites.trackIds.count == 20)
    }

    @Test func aMixGetsShorterRatherThanFilledByOneArtist() throws {
        let starred = Set(library().filter { $0.id.hasPrefix("a0") }.map(\.id) + (0..<8).map { "a\($0 % 4 + 1)-b\($0 % 3)-\($0)" })
        let favorites = try #require(catalog(library(starred: starred)).madeForYou(day: "d", size: 20).first { $0.kind == .favorites })
        #expect(favorites.trackIds.count < 20 && favorites.trackIds.count >= Catalog.minimumMix)
        #expect(counts(favorites.trackIds, artist).values.max() ?? 0 <= 4 && isSpaced(favorites.trackIds))
    }

    @Test func capsGiveWayWhenNothingElseIsLeft() {
        let one = library().filter { $0.id.hasPrefix("a0-b0") }
        let c = catalog(one)
        #expect(c.capped(one.map(\.id), size: 20).count == 8)
        #expect(c.capped(one.map(\.id), size: 20).prefix(2) == ["a0-b0-0", "a0-b0-1"])
    }

    @Test func stationsCapArtistsAndAlbums() {
        let list = catalog().radio(seeds: ["a0-b0-0"], count: 30, seed: 9)
        #expect(list.count == 30)
        #expect(counts(list, artist).values.max() ?? 0 <= 6 && counts(list, album).values.max() ?? 0 <= 3)
    }

    @Test func songsHeardInTheLastHoursComeLast() throws {
        let starred = Set((0..<18).map { "a\($0 % 6)-b\($0 % 3)-\($0 % 8)" })
        let heard = ["a0-b0-0", "a1-b1-1", "a2-b2-2", "a3-b0-3"]
        let c = catalog(library(starred: starred), history: heard.enumerated().map { play($1, Double($0 + 1) * 1800) })
        let favorites = try #require(c.madeForYou(day: "d", size: 8).first { $0.kind == .favorites })
        #expect(favorites.trackIds.count == 8 && Set(favorites.trackIds).isDisjoint(with: heard))
    }

    @Test func stationsMixInRarelyPlayedSongsCloseToTheSeed() {
        // Everything is played a lot except two rock albums and one jazz album.
        let rare: Set<String> = ["a1-b2", "a2-b2", "a4-b2"]
        let plays = Dictionary(uniqueKeysWithValues: library().map { ($0.id, rare.contains(album($0.id)) ? 0 : 10) })
        let c = catalog(library(plays: plays))
        let list = c.radio(seeds: ["a0-b0-0"], count: 20, seed: 3)
        let found = list.filter { rare.contains(album($0)) }
        #expect([4, 9, 14].allSatisfy { rare.contains(album(list[$0])) })
        #expect(found.count >= 3 && found.prefix(3).allSatisfy { !$0.hasPrefix("a4") })  // rock, like the seed, until the station drifts
        #expect(catalog().radio(seeds: ["a0-b0-0"], count: 20, seed: 3).count == 20)
    }

    @Test func rarelyPlayedIsTheLeastPlayedTenth() {
        #expect(catalog().rarePlays == 1)
        let plays = Dictionary(uniqueKeysWithValues: library().enumerated().map { ($1.id, 5 + $0) })
        #expect(catalog(library(plays: plays)).rarePlays == 5 + 14)  // the 15th of 144
        #expect(Catalog.quantile([], 0.5) == 0 && Catalog.quantile([3, 1, 2], 1) == 3)
    }
}

@Suite struct TimeOfDayTests {
    /// Artist 3 is played on weekday mornings, artist 4 on weekday evenings, as often.
    private var history: [PlayEvent] {
        (1...20).flatMap { d in
            [play("a3-b\(d % 3)-\(d % 8)", Double(d) * 7 * day), play("a4-b\(d % 3)-\(d % 8)", Double(d) * 7 * day - 10 * 3600)]
        }
    }

    @Test func partsOfTheDay() {
        #expect([4, 5, 10, 11, 16, 17, 21, 22].map { DayPart(hour: $0) } == [.night, .morning, .morning, .afternoon, .afternoon, .evening, .evening, .night])
        #expect(catalog().dayPart == .morning && catalog(at: now.addingTimeInterval(10 * 3600)).dayPart == .evening)
    }

    @Test func scoreFollowsThePartAndKindOfDay() {
        let morning = catalog(history: history)
        #expect(morning.context.score("a3-b1-1") >= 0.5 && morning.context.score("a4-b1-1") < morning.context.score("a3-b1-1"))
        #expect(morning.context.score("a4-b1-1") > 0)  // still a weekday
        let saturday = catalog(history: history, at: now.addingTimeInterval(day))
        #expect(saturday.context.score("a3-b1-1") < morning.context.score("a3-b1-1"))
        #expect(catalog().context.score("a3-b1-1") == 0)
    }

    @Test func topPicksFollowTheTime() {
        let morning = catalog(history: history).topPicks(day: "d")
        let evening = catalog(history: history, at: now.addingTimeInterval(10 * 3600)).topPicks(day: "d")
        #expect(morning.isEmpty)  // three albums are too few
        let more = history + (1...20).map { play("a5-b\($0 % 3)-\($0 % 8)", Double($0) * 7 * day) }
        let picks = catalog(history: more).topPicks(day: "d")
        #expect(Set(picks) == Set((0..<3).flatMap { b in ["a3-b\(b)", "a5-b\(b)"] }))
        #expect(evening.isEmpty && catalog().topPicks(day: "d").isEmpty)
        #expect(picks == catalog(history: more).topPicks(day: "d"))
    }

    @Test func autoPlayFavorsSongsOfThisTime() {
        func artist3(_ time: Date) -> Int {
            let c = catalog(history: history, at: time)
            // The queue holds every song of artist 5: AutoPlay picks from artists 3 and 4, alike but for the time.
            let queue = (0..<3).flatMap { b in (0..<8).map { "a5-b\(b)-\($0)" } }
            return (0..<20).map { c.continuation(of: queue, count: 3, seed: UInt64($0)) }.joined().filter { $0.hasPrefix("a3") }.count
        }
        #expect(artist3(now) > artist3(now.addingTimeInterval(10 * 3600)))
    }
}

@Suite struct ExplanationTests {
    @Test func reasonNamesTheSharedSignals() {
        let c = catalog(playlists: [["a0-b0-0"] + (0..<8).map { "a1-b0-\($0)" }])
        #expect(c.reason(seeds: ["a0-b0-0"], picks: (0..<8).map { "a0-b1-\($0)" }) == "More by Artist 0 · Rock · 1990s")
        #expect(c.reason(seeds: ["a0-b0-0"], picks: (0..<8).map { "a1-b0-\($0)" }) == "Similar artists · Rock · 1990s")
        #expect(c.reason(seeds: ["a0-b0-0"], picks: (0..<8).map { "a5-b2-\($0)" }) == "Songs like this one")
        #expect(c.reason(seeds: [], picks: ["a0-b0-1"]).isEmpty)
        let morning = catalog(history: (1...10).map { play("a4-b2-\($0 % 8)", Double($0) * 7 * day) })
        let picks = (0..<8).map { "a4-b2-\($0)" }
        #expect(morning.reason(seeds: ["a5-b0-0"], picks: picks, timeOfDay: true) == "Jazz · 2010s · Often Played in the Morning")
        #expect(morning.reason(seeds: ["a5-b0-0"], picks: picks) == "Jazz · 2010s")
    }

    @Test func becauseShelvesExplainThemselves() {
        let c = catalog(library(starred: ["a0-b0-0", "a3-b0-0"]))
        let shelves = c.becauseYouListened(day: "d", shelves: 2, size: 10)
        #expect(shelves.count == 2 && shelves.allSatisfy { !$0.reason.isEmpty && $0.reason != "Songs like this one" })
    }

    @Test func discoverFindsUnplayedAlbumsOfYourTaste() {
        let plays = Dictionary(uniqueKeysWithValues: library().filter { $0.id.hasPrefix("a0-b0") || $0.id.hasPrefix("a0-b1") }.map { ($0.id, 5) })
        let c = catalog(library(plays: plays))
        let albums = c.discover(day: "d")
        #expect(albums.contains("a0-b2") && albums.count == 5)  // rock albums not played yet, two per artist
        #expect(albums.allSatisfy { Int($0.dropFirst().prefix(1))! < 3 && !["a0-b0", "a0-b1"].contains($0) })
        #expect(albums == c.discover(day: "d") && catalog().discover(day: "d").isEmpty)
    }
}
