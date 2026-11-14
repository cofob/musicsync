import Foundation
import Recommend
import Subsonic
import Testing
@testable import Library

@Suite struct SmartPlaylistTests {
    typealias P = SmartPlaylist
    /// 2026-11-14 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_794_657_600)
    let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

    /// Five songs of five albums; the third album is a compilation. Song fields follow the server's JSON.
    private func fixture() throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        for sql in Schema.statements { try db.exec(sql) }
        let albums: [[String: Any]] = [
            ["id": "al1", "name": "Homogenic", "artist": "Björk"], ["id": "al2", "name": "Группа крови", "artist": "Кино"],
            ["id": "al3", "name": "Hits", "artist": "Various Artists", "isCompilation": true], ["id": "al4", "name": "Debut", "artist": "Björk"],
            ["id": "al5", "name": "Quiet", "artist": "Nobody"],
        ]
        for a in albums {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: a), as: UTF8.self)
            try db.run("INSERT INTO albums(id, name, artist, sortName, artistKey, fingerprint, json) VALUES(?, ?, ?, ?, ?, '', ?)",
                       [a["id"] as! String, a["name"] as! String, a["artist"] as? String, sortKey(a["name"] as? String), sortKey(a["artist"] as? String), json])
        }
        let songs: [[String: Any]] = [
            ["id": "s1", "albumId": "al1", "title": "Night Drive", "artist": "Björk", "album": "Homogenic", "genre": "Electronic", "year": 1997,
             "duration": 300, "suffix": "flac", "bitRate": 900, "size": 30_000_000, "created": "2024-01-10T08:00:00Z", "playCount": 5,
             "userRating": 5, "starred": "2025-01-01T00:00:00Z"],
            ["id": "s2", "albumId": "al2", "title": "Ночь", "artist": "Кино", "album": "Группа крови", "genre": "Rock", "year": 1988,
             "duration": 240, "suffix": "mp3", "bitRate": 320, "size": 9_000_000, "created": "2026-11-01T10:00:00.123Z", "playCount": 0],
            ["id": "s3", "albumId": "al3", "title": "100% Pure", "artist": "Various", "album": "Hits", "albumArtist": "Various Artists",
             "genre": "Pop", "year": 2005, "duration": 180, "suffix": "mp3", "bitRate": 128, "size": 3_000_000,
             "created": "2025-06-15T12:00:00Z", "playCount": 2, "userRating": 3],
            ["id": "s4", "albumId": "al4", "title": "a_b", "artist": "Björk", "album": "Debut", "genre": "Electronic", "year": 1993,
             "duration": 200, "suffix": "flac", "bitRate": 1000, "size": 25_000_000, "created": "2023-03-03T00:00:00Z", "playCount": 10, "userRating": 4],
            ["id": "s5", "albumId": "al5", "title": "Silence", "artist": "Nobody", "album": "Quiet"],
        ]
        for s in songs {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: s), as: UTF8.self)
            try db.run("""
                INSERT INTO songs(id, albumId, title, artist, album, duration, suffix, bitRate, created, playCount, starred,
                                  titleKey, artistKey, albumKey, json) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [s["id"] as! String, s["albumId"] as? String, s["title"] as! String, s["artist"] as? String, s["album"] as? String,
                      s["duration"] as? Int, s["suffix"] as? String, s["bitRate"] as? Int, s["created"] as? String, s["playCount"] as? Int ?? 0,
                      s["starred"] as? String, sortKey(s["title"] as? String), sortKey(s["artist"] as? String), sortKey(s["album"] as? String), json])
        }
        return db
    }

    private func playlist(_ match: P.Match = .all, _ items: [P.Item], limit: P.Limit = P.Limit()) -> P {
        var p = P(name: "Test")
        p.rules = P.Group(match: match, items: items)
        p.limit = limit
        return p
    }

    private func rule(_ field: P.Field, _ op: P.Operator, _ text: String = "", _ number: Double = 0, _ number2: Double = 0) -> P.Item {
        .rule(P.Rule(field: field, op: op, text: text, number: number, number2: number2))
    }

    private func ids(_ db: SQLiteConnection, _ p: P, plays: [String: SongStats] = [:], downloaded: Set<String> = []) throws -> Set<String> {
        Set(try LibraryDatabase.smartMatches(db, p, plays: plays, downloaded: downloaded, now: now).ids)
    }

    private func ids(_ db: SQLiteConnection, _ items: P.Item..., match: P.Match = .all) throws -> Set<String> {
        try ids(db, playlist(match, items))
    }

    private func day(_ text: String) -> Double { (try! Date(text, strategy: .iso8601)).timeIntervalSince1970 }

    @Test func valuesAreBoundNotInlined() throws {
        let evil = "x'; DROP TABLE songs; --"
        let query = SmartQuery(playlist(.any, [rule(.genre, .is, evil), rule(.year, .greater, "", 1990)]), now: now)
        #expect(!query.sql.contains("DROP") && !query.sql.contains("1990"))
        #expect(query.params == [.text(evil), .real(1990)])
        #expect(!query.usesHistory && !query.usesDownloads)
        let db = try fixture()
        #expect(try ids(db, rule(.genre, .is, evil)).isEmpty)
        #expect(try db.scalar("SELECT COUNT(*) FROM songs") == 5)
    }

    @Test func textRules() throws {
        let db = try fixture()
        #expect(try ids(db, rule(.artist, .contains, "BJORK")) == ["s1", "s4"])  // case and diacritics folded
        #expect(try ids(db, rule(.title, .is, "НОЧЬ")) == ["s2"])
        #expect(try ids(db, rule(.title, .startsWith, "night")) == ["s1"])
        #expect(try ids(db, rule(.title, .endsWith, "pure")) == ["s3"])
        #expect(try ids(db, rule(.title, .contains, "%")) == ["s3"])  // wildcards match only themselves
        #expect(try ids(db, rule(.title, .contains, "_")) == ["s4"])
        #expect(try ids(db, rule(.genre, .notContains, "rock")) == ["s1", "s3", "s4", "s5"])  // no genre counts as not containing
        #expect(try ids(db, rule(.format, .is, "MP3")) == ["s2", "s3"])
        #expect(try ids(db, rule(.format, .isNot, "mp3")) == ["s1", "s4", "s5"])
        #expect(try ids(db, rule(.albumArtist, .is, "various artists")) == ["s3"])
        #expect(try ids(db, rule(.albumArtist, .is, "Björk")) == ["s1", "s4"])  // the album's artist when the song has none
        #expect(try ids(db, rule(.album, .contains, "крови")) == ["s2"])
    }

    @Test func numberRules() throws {
        let db = try fixture()
        #expect(try ids(db, rule(.year, .inRange, "", 2000, 1990)) == ["s1", "s4"])
        #expect(try ids(db, rule(.bitRate, .greater, "", 500)) == ["s1", "s4"])
        #expect(try ids(db, rule(.rating, .is, "", 5)) == ["s1"])
        #expect(try ids(db, rule(.rating, .isNot, "", 0)) == ["s1", "s3", "s4"])
        #expect(try ids(db, rule(.duration, .less, "", 210)) == ["s3", "s4", "s5"])
        #expect(try ids(db, rule(.year, .is, "", .nan)) == ["s5"])  // a broken value reads as 0
    }

    @Test func dateRules() throws {
        let db = try fixture()
        func dates(_ op: P.Operator, _ a: Double, _ b: Double = 0) throws -> Set<String> {
            Set(try LibraryDatabase.smartMatches(db, playlist(.all, [rule(.dateAdded, op, "", a, b)]), plays: [:], downloaded: [], now: now).ids)
        }
        #expect(try dates(.inLast, 30) == ["s2"])
        #expect(try dates(.notInLast, 30) == ["s1", "s3", "s4", "s5"])  // never added counts as not recent
        // Whole days in the user's calendar; fixed to UTC here.
        let query = SmartQuery(playlist(.all, [rule(.dateAdded, .is, "", day("2025-06-15T20:00:00Z"))]), now: now, calendar: utc)
        #expect(query.params == [.real(day("2025-06-15T00:00:00Z")), .real(day("2025-06-16T00:00:00Z"))])
        #expect(try dates(.less, day("2024-01-01T12:00:00Z")) == ["s4"])
        #expect(try dates(.greater, day("2025-06-16T12:00:00Z")) == ["s2"])
        #expect(try dates(.inRange, day("2024-02-01T12:00:00Z"), day("2023-01-01T12:00:00Z")) == ["s1", "s4"])
    }

    @Test func flagsHistoryAndDownloads() throws {
        let db = try fixture()
        #expect(try ids(db, rule(.favorite, .isTrue)) == ["s1"])
        #expect(try ids(db, rule(.favorite, .isFalse)) == ["s2", "s3", "s4", "s5"])
        #expect(try ids(db, rule(.compilation, .isTrue)) == ["s3"])
        #expect(try ids(db, playlist(.all, [rule(.downloaded, .isTrue)]), downloaded: ["s2"]) == ["s2"])
        #expect(try ids(db, playlist(.all, [rule(.downloaded, .isFalse)]), downloaded: ["s2"]) == ["s1", "s3", "s4", "s5"])
        let plays = ["s2": SongStats(plays: 7, lastPlayed: now.addingTimeInterval(-86400)), "s1": SongStats(plays: 1, lastPlayed: now.addingTimeInterval(-40 * 86400))]
        // The higher of the server's count and the local history.
        #expect(try ids(db, playlist(.all, [rule(.playCount, .greater, "", 6)]), plays: plays) == ["s2", "s4"])
        #expect(try ids(db, playlist(.all, [rule(.playCount, .is, "", 5)]), plays: plays) == ["s1"])
        #expect(try ids(db, playlist(.all, [rule(.lastPlayed, .inLast, "", 7)]), plays: plays) == ["s2"])
        #expect(try ids(db, playlist(.all, [rule(.lastPlayed, .notInLast, "", 7)]), plays: plays) == ["s1", "s3", "s4", "s5"])
        // A new evaluation replaces the old temporary rows.
        #expect(try ids(db, playlist(.all, [rule(.playCount, .greater, "", 6)]), plays: [:]) == ["s4"])
        #expect(SmartQuery(playlist(.all, [rule(.playCount, .greater)]), now: now).usesHistory)
        #expect(SmartQuery(playlist(.all, [rule(.downloaded, .isTrue)]), now: now).usesDownloads)
    }

    @Test func matchAnyAndNestedGroups() throws {
        let db = try fixture()
        let björk = P.Item.group(P.Group(match: .all, items: [rule(.artist, .contains, "björk"), rule(.year, .greater, "", 1995)]))
        #expect(try ids(db, rule(.genre, .is, "rock"), björk, match: .any) == ["s1", "s2"])
        #expect(try ids(db, rule(.genre, .is, "rock"), björk, match: .all).isEmpty)
        #expect(try ids(db, playlist(.all, [])) == ["s1", "s2", "s3", "s4", "s5"])  // no rules: every song
        #expect(try ids(db, playlist(.any, [.group(P.Group(match: .any, items: []))])).count == 5)
    }

    @Test func limits() throws {
        let db = try fixture()
        func pick(_ amount: Double, _ unit: P.Limit.Unit, by: P.Order, seed: UInt64 = 1) throws -> P.Matches {
            var limit = P.Limit()
            limit.isOn = true
            limit.amount = amount
            limit.unit = unit
            limit.by = by
            var p = playlist(.all, [], limit: limit)
            p.seed = seed
            return try LibraryDatabase.smartMatches(db, p, plays: [:], downloaded: [], now: now)
        }
        #expect(try pick(2, .songs, by: .mostPlayed).ids == ["s4", "s1"])
        #expect(try pick(2, .songs, by: .leastPlayed).ids == ["s5", "s2"])
        #expect(try pick(1, .songs, by: .highestRated).ids == ["s1"])
        // 4 + 3 minutes fit in 9; the next song (5 minutes) does not.
        let minutes = try pick(9, .minutes, by: .recentlyAdded)
        #expect(minutes.ids == ["s2", "s3"] && minutes.duration == 420 && minutes.size == 12_000_000)
        #expect(try pick(0.04, .gigabytes, by: .highestRated).ids == ["s1"])
        #expect(try pick(40, .megabytes, by: .highestRated).ids == ["s1"])
        #expect(try pick(1, .hours, by: .recentlyAdded).ids.count == 5)
        // Random: the same seed picks the same songs.
        let random = try pick(3, .songs, by: .random, seed: 42)
        let again = try pick(3, .songs, by: .random, seed: 42)
        #expect(random.ids.count == 3 && random == again)
        // Without a limit: album order (artist, album, track).
        #expect(try LibraryDatabase.smartMatches(db, playlist(.all, []), plays: [:], downloaded: [], now: now).ids == ["s4", "s1", "s5", "s3", "s2"])
    }

    @Test func libraryUsesHistoryAndFrozenSongs() async throws {
        let dir = TempDir()
        let library = Library(server: ServerConfig(baseURL: URL(string: "http://stub")!, username: "demo"), settings: manualSettings(),
                              directory: dir.url, coversDirectory: dir.url.appendingPathComponent("covers"))
        try await seed(library.database, albums: [(album("al", "Album", songs: 2), [song("a", "Alpha"), song("b", "Beta", track: 2)])])
        try await library.history.record(PlayEvent(songId: "b", startedAt: Date(), played: 200, duration: 200, source: .album))
        var p = playlist(.all, [rule(.playCount, .greater, "", 0)])
        #expect(await library.smartSongs(p, downloaded: []).map(\.id) == ["b"])
        // Not live: the saved songs stay, in their order, even when they no longer match.
        p.liveUpdating = false
        p.frozen = ["a", "gone"]
        let matches = await library.smartMatches(p, downloaded: [])
        #expect(matches.ids == ["a"] && matches.duration == 200)
    }

    @Test func savedListSkipsUnreadableEntries() throws {
        var p = P(name: "Loud")
        p.rules.items.append(.group(P.Group(match: .any, items: [rule(.genre, .is, "Rock")])))
        let data = try JSONEncoder().encode(SmartPlaylistList(playlists: [p]))
        #expect(try JSONDecoder().decode(SmartPlaylistList.self, from: data).playlists == [p])
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var list = json["playlists"] as! [[String: Any]]
        list.append(["id": "smart:x", "name": "From a newer version", "rules": ["unknown": 1]])
        json["playlists"] = list
        let decoded = try JSONDecoder().decode(SmartPlaylistList.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.playlists == [p] && decoded.version == SmartPlaylistList.currentVersion)
    }

    @Test func changingTheFieldKeepsAFittingOperator() {
        var r = P.Rule(field: .title, op: .startsWith, text: "x")
        r.setField(.artist)
        #expect(r.op == .startsWith && r.text == "x")
        r.setField(.year)
        #expect(r.op == .is && r.text.isEmpty)
        r.setField(.lastPlayed)
        #expect(r.op == .inLast && r.number == 30)
        r.setField(.favorite)
        #expect(r.op == .isTrue)
        #expect(P.isSmart(P().id) && !P.isSmart("pl-1") && P().duplicated().id != P().id)
    }
}
