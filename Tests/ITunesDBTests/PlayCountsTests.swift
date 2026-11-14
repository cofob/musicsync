import Foundation
import Support
import Testing
@testable import ITunesDB

@Suite struct PlayCountsTests {
    private func file(entrySize: Int, _ entries: [[UInt32]]) -> Data {
        var w = BinaryWriter()
        w.tag("mhdp"); w.u32(0x60); w.u32(UInt32(entrySize)); w.u32(UInt32(entries.count)); w.pad(toCount: 0x60)
        for e in entries { for v in e { w.u32(v) }; w.zeros(entrySize - 4 * e.count) }
        return w.data
    }

    @Test(arguments: [0x0C, 0x10, 0x14, 0x1C])
    func parsesAllEntrySizes(size: Int) throws {
        let pc = try PlayCounts.parse(file(entrySize: size, [[2, 3_700_000_000, 5, 60, 0, 4, 3_700_000_100]]))
        let e = try #require(pc.entries.first)
        #expect(e.playCount == 2)
        #expect(e.lastPlayed == MacTime.date(3_700_000_000))
        #expect(e.bookmark == 5)
        #expect(e.rating == (size >= 0x10 ? 60 : nil))
        #expect(e.skipCount == (size >= 0x1C ? 4 : 0))
        #expect((e.lastSkipped != nil) == (size >= 0x1C))
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: ITunesDBError.self) { try PlayCounts.parse(Data(repeating: 1, count: 40)) }
        #expect(throws: (any Error).self) { try PlayCounts.parse(file(entrySize: 0x1C, [[1]]).dropLast(20)) }
    }

    @Test func mergeFollowsLibgpodRules() throws {
        var db = sampleDB()
        db.tracks[0].playCount = 3
        db.tracks[0].timePlayed = Date(timeIntervalSince1970: 1_600_000_000)
        db.tracks[1].markUnplayed = 2
        let played = Date(timeIntervalSince1970: 1_750_000_000)
        let pc = PlayCounts(entries: [
            PlayCountEntry(playCount: 2, lastPlayed: played, bookmark: 7, rating: 40, skipCount: 1),
            PlayCountEntry(playCount: 1, lastPlayed: nil, rating: 80),
            PlayCountEntry(playCount: 0, lastPlayed: nil, rating: 80),
        ])
        let deltas = db.merge(pc)
        #expect(deltas.map(\.trackID) == [db.tracks[0].id, db.tracks[1].id])
        #expect(deltas.map(\.plays) == [2, 1])
        #expect(deltas[0].lastPlayed == played)
        #expect(db.tracks[0].playCount == 5 && db.tracks[0].skipCount == 1)
        #expect(db.tracks[0].rating == 40 && db.tracks[0].bookmarkTime == 7)
        #expect(db.tracks[0].timePlayed == MacTime.date(MacTime.mac(played)))
        #expect(db.tracks[1].timePlayed == nil && db.tracks[1].markUnplayed == 1)
        #expect(db.tracks[3].playCount == 0)

        let parsed = try ITunesDB.parse(try db.serialize())
        #expect(parsed.tracks[0].playCount == 5 && parsed.tracks[0].rating == 40)
    }

    @Test func otgPlaylists() throws {
        var w = BinaryWriter()
        w.tag("mhpo"); w.u32(0x14); w.u32(4); w.u32(3); w.u32(0)
        [3, 0, 99].forEach { w.u32($0) }
        let positions = try OTGPlaylists.parse(w.data)
        #expect(positions == [3, 0, 99])

        var db = sampleDB()
        let added = db.addOTGPlaylists([positions, []])
        #expect(added.count == 1)
        #expect(added[0].name == "On-The-Go 1")
        #expect(added[0].trackIDs == [db.tracks[3].id, db.tracks[0].id])
        #expect(db.playlists.last == added[0])
        #expect(throws: ITunesDBError.self) { try OTGPlaylists.parse(Data(count: 32)) }
    }
}
