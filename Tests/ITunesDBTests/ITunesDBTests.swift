import Foundation
import Support
import Testing
@testable import ITunesDB

@Suite struct ITunesDBTests {
    @Test func sectionsAreWrittenInLibgpodOrder() throws {
        let data = try sampleDB().serialize()
        #expect(try validateStructure(data) == [1, 3, 2, 4, 8, 6, 10, 5])
        let r = BinaryReader(data)
        #expect(try r.int(4) == 0xF4)
        #expect(try r.u32(at: 0x10) == 0x30)
    }

    @Test func roundTripKeepsFields() throws {
        let db = sampleDB()
        let parsed = try ITunesDB.parse(try db.serialize())
        #expect(parsed.name == "My iPod")
        #expect(parsed.tracks.count == 4)
        for (a, b) in zip(db.tracks, parsed.tracks) {
            var b = b
            #expect(b.raw != nil)
            b.raw = nil
            var a = a
            a.fileTypeDescription = "AAC audio file"
            #expect(a == b)
        }
        #expect(parsed.playlists.count == 2)
        #expect(parsed.playlists[0].isMaster)
        #expect(parsed.playlists[0].trackIDs == db.tracks.map(\.id))
        #expect(parsed.playlists[1].name == "Mix")
        #expect(parsed.playlists[1].trackIDs == db.playlists[1].trackIDs)
        #expect(parsed.playlists[1].persistentId == db.playlists[1].persistentId)
        #expect(!parsed.playlists[1].isMaster)
    }

    @Test func serializingTwiceIsStable() throws {
        let first = try sampleDB().serialize(firewireGuid: [0, 0x0A, 0x27, 0, 0x12, 0x34, 0xAB, 0xCD])
        let second = try ITunesDB.parse(first).serialize(firewireGuid: [0, 0x0A, 0x27, 0, 0x12, 0x34, 0xAB, 0xCD])
        #expect(first == second)
    }

    @Test func idsAreStableAndNewIdsFollowMax() {
        var db = ITunesDB.empty(name: "x")
        #expect(db.nextTrackID() == 52)
        let a = db.addTrack(sampleTrack(1))
        let b = db.addTrack(sampleTrack(2))
        #expect(a == 53 && b == 54)
        db.removeTrack(id: a)
        #expect(db.tracks.map(\.id) == [54])
        #expect(db.playlists[0].trackIDs == [54])
        #expect(db.nextTrackID() == 55)
        #expect(db.nextTrackID() == 56)
    }

    @Test func removeTrackLeavesOtherIdsAndPlaylists() throws {
        var db = sampleDB()
        let kept = db.tracks[3].id
        db.removeTrack(id: db.tracks[0].id)
        let parsed = try ITunesDB.parse(try db.serialize())
        #expect(parsed.tracks.count == 3)
        #expect(parsed.tracks.last?.id == kept)
        #expect(parsed.playlists[1].trackIDs == [kept])
    }

    @Test func albumAndArtistIdsArePatchedIntoTracks() throws {
        let parsed = try ITunesDB.parse(try sampleDB().serialize())
        func ids(_ t: Track) throws -> [UInt32] {
            let r = BinaryReader(t.raw!.header)
            return [try r.u32(at: 0x120), try r.u32(at: 0x1E0), try r.u32(at: 0x1F4)]
        }
        let first = try ids(parsed.tracks[0]), third = try ids(parsed.tracks[2]), other = try ids(parsed.tracks[3])
        #expect(first[0] == 1 && first[1] == 1)
        #expect(third[0] == first[0] && third[1] == first[1])
        #expect(other[0] == 2 && other[1] == 2)
        let second = try ids(parsed.tracks[1])
        #expect(first[2] != 0 && first[2] != second[2])
        let id24 = try BinaryReader(parsed.header).u64(at: 0x24)
        #expect(try BinaryReader(parsed.tracks[0].raw!.header).u64(at: 0x124) == id24)
    }

    @Test func playlistPrefsMhodHasLibgpodSize() {
        #expect(Mhod.playlistPrefs().count == 0x288)
        #expect(Mhod.position(7).count == 44)
        #expect(Mhod.string(1, "ab").count == 44)
    }

    @Test func mhitHeaderIsLibgpodSized() throws {
        let t = try ITunesDB.parse(try sampleDB().serialize()).tracks[0]
        #expect(t.raw!.header.count == 0x248)
        let r = BinaryReader(t.raw!.header)
        #expect(try r.u32(at: 0x14) == 1)
        #expect(try r.tag(at: 0x18).isEmpty == false)
        #expect(try r.u32(at: 0x18) == 0x4D34_4120)
        #expect(try r.u16(at: 0x7E) == 0xFFFF)
        #expect(try r.u16(at: 0x90) == 0x33)
        #expect(try r.u64(at: 0x134) == 0x8080_8080_8080)
        #expect(try r.u64(at: 0xA8) == t.dbid)
    }

    @Test func foreignTrackBytesAreKept() throws {
        var db = try ITunesDB.parse(try sampleDB().serialize())
        // Simulate content written by another tool: unknown header byte, extra mhod, unknown section.
        var raw = try #require(db.tracks[1].raw)
        var header = raw.header
        header[0x1C8] = 0xAB
        header[0xE4] = 0xCD
        let extra = Mhod.string(14, "Description")
        raw = RawTrack(header: header, mhods: raw.mhods + [extra])
        db.tracks[1].raw = raw
        var unknown = BinaryWriter()
        unknown.tag("mhsd"); unknown.u32(96); unknown.u32(100); unknown.u32(9); unknown.zeros(80); unknown.bytes(Data("abcd".utf8))
        db.sections.append(RawSection(type: 9, data: unknown.data))
        db.playlists[1].raw?.mhods.append(Mhod.string(99, "keep me"))

        let written = try db.serialize()
        let parsed = try ITunesDB.parse(written)
        let out = try #require(parsed.tracks[1].raw)
        #expect(out.header[0x1C8] == 0xAB && out.header[0xE4] == 0xCD)
        #expect(out.mhods.contains(extra))
        #expect(out.mhods == raw.mhods)
        #expect(parsed.sections.contains { $0.type == 9 && $0.data == unknown.data })
        #expect(parsed.playlists[1].raw?.mhods.contains(Mhod.string(99, "keep me")) == true)
        #expect(try validateStructure(written) == [1, 3, 2, 4, 8, 6, 10, 5, 9])
        #expect(try parsed.serialize() == written)
    }

    @Test func onlyOwnedFieldsChangeInForeignHeader() throws {
        var db = try ITunesDB.parse(try sampleDB().serialize())
        let before = try #require(db.tracks[0].raw).header
        db.tracks[0].playCount = 9
        db.tracks[0].skipCount = 2
        db.tracks[0].rating = 100
        db.tracks[0].timePlayed = Date(timeIntervalSince1970: 1_750_000_000)
        db.tracks[0].setArtwork(imageID: 123, sourceSize: 4567)
        // Move the track so album/artist ids change as well.
        db.tracks[0].title = "Renamed"
        let after = try #require(ITunesDB.parse(try db.serialize()).tracks[0].raw).header
        let changed = Set(before.indices.filter { before[$0] != after[$0] })
        let owned: Set<Int> = [0x08, 0x1F, 0x50, 0x58, 0x59, 0x5A, 0x5B, 0x7C, 0x80, 0x81, 0x9C, 0xA4, 0x160]
        #expect(changed.isSubset(of: owned), "unexpected changes at \(changed.subtracting(owned).sorted())")
        let t = try ITunesDB.parse(try db.serialize()).tracks[0]
        #expect(t.playCount == 9 && t.skipCount == 2 && t.rating == 100)
        #expect(t.mhiiLink == 123 && t.artworkCount == 1 && t.artworkSize == 4567 && t.hasArtwork)
        #expect(t.title == "Renamed")
    }

    @Test func masterPlaylistHasSortIndexes() throws {
        let data = try sampleDB().serialize()
        let r = BinaryReader(data)
        // Find the master mhyp in section 2 and count its mhods.
        var offset = try r.int(4)
        while try r.u32(at: offset + 12) != 2 { offset += try r.int(offset + 8) }
        let mhyp = offset + 96 + 92
        try r.expectTag("mhyp", at: mhyp)
        #expect(try r.int(mhyp + 12) == 12)
        var o = mhyp + 108
        var types: [UInt32] = []
        for _ in 0..<12 { types.append(try r.u32(at: o + 12)); o += try r.int(o + 8) }
        #expect(types == [1, 100, 52, 53, 52, 53, 52, 53, 52, 53, 52, 53])
    }

    @Test func jumpLetterFollowsSortKey() throws {
        var db = ITunesDB.empty(name: "x")
        var track = Track()
        track.title = "(Untitled)"
        db.addTrack(track)
        let data = try db.serialize()
        let jump = try #require(data.range(of: Data("mhod".utf8) + Data([0x18, 0, 0, 0, 0x34, 0, 0, 0, 0x35, 0, 0, 0])))
        #expect(data[jump.lowerBound + 40] == 0x30)
    }

    @Test func emptyDatabaseIsValid() throws {
        let data = try ITunesDB.empty(name: "Empty").serialize()
        #expect(try validateStructure(data) == [1, 3, 2, 4, 8, 6, 10, 5])
        let parsed = try ITunesDB.parse(data)
        #expect(parsed.tracks.isEmpty && parsed.name == "Empty")
    }

    @Test func rejectsGarbage() {
        #expect(throws: ITunesDBError.self) { try ITunesDB.parse(Data(repeating: 0, count: 100)) }
        #expect(throws: (any Error).self) { try ITunesDB.parse(Data("mhbd".utf8)) }
    }

    @Test func locationHelpers() {
        #expect(ITunesDB.ipodLocation(relativePath: "iPod_Control/Music/F07/ABCD.m4a") == ":iPod_Control:Music:F07:ABCD.m4a")
        #expect(ITunesDB.relativePath(ipodLocation: ":iPod_Control:Music:F07:ABCD.m4a") == "iPod_Control/Music/F07/ABCD.m4a")
    }

    @Test func soundcheckFromReplayGain() {
        #expect(soundcheck(fromReplayGainDB: 0) == 1000)
        #expect(soundcheck(fromReplayGainDB: -6) == 3981)
        #expect(soundcheck(fromReplayGainDB: 6) == 251)
        #expect(soundcheck(fromReplayGainDB: .nan) == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUSICSYNC_TEST_ITUNESDB"] != nil))
    func realDeviceDatabase() throws {
        let env = ProcessInfo.processInfo.environment
        let data = try Data(contentsOf: URL(fileURLWithPath: env["MUSICSYNC_TEST_ITUNESDB"]!))
        let db = try ITunesDB.parse(data)
        let again = try ITunesDB.parse(try db.serialize())
        #expect(again.tracks.count == db.tracks.count)
        #expect(again.playlists.count == db.playlists.count)
        if let guidString = env["MUSICSYNC_TEST_GUID"] {
            let guid = try Hash58.parseGuid(guidString)
            #expect(Hash58.verify(data, guid: guid))
            #expect(Hash58.verify(try db.serialize(firewireGuid: guid), guid: guid))
        }
    }
}
