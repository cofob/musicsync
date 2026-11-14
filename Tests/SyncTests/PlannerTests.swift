import Foundation
import struct Subsonic.Song
import Testing
@testable import ITunesDB
@testable import Sync
@testable import Transcode

@Suite struct PlannerTests {
    let free: Int64 = 10_000_000_000

    /// A device that holds `s1` as a managed stock track plus one foreign track.
    func fixture(songs: [DesiredSong], present: [DesiredSong], playlists: [DesiredPlaylist] = [],
                 manifestEdit: (inout Manifest) -> Void = { _ in }) -> PlannerInput {
        var manifest = Manifest(serverKey: "s")
        var tracks = [makeTrack(1)]
        for (i, d) in present.enumerated() {
            var t = makeTrack(10 + i, dbid: UInt64(500 + i))
            t.title = d.tags.title
            tracks.append(t)
            manifest.entries[d.id] = makeEntry(d, dbid: UInt64(500 + i), trackID: UInt32(60 + i))
        }
        manifestEdit(&manifest)
        return PlannerInput(desired: songs, playlists: playlists, manifest: manifest,
                            library: makeLibrary(tracks: tracks, manifest: manifest), freeBytes: free)
    }

    @Test func addsNewSongsAndEstimatesSize() {
        let flac = makeDesired(makeSong("a", suffix: "flac", duration: 100))
        let mp3 = makeDesired(makeSong("b", size: 8_000_000, suffix: "mp3", duration: 200, bitRate: 320))
        let plan = SyncPlanner.plan(fixture(songs: [flac, mp3], present: []))
        #expect(plan.add.map(\.id) == ["a", "b"])
        // FLAC is re-encoded at 256 kbps: 100 s * 32 000 B/s (+2 % and a small overhead). MP3 is copied.
        #expect(plan.addBytes > 3_200_000 + 8_000_000 && plan.addBytes < 3_200_000 * 11 / 10 + 8_000_000)
        #expect(plan.fits)
        #expect(plan.touchesStock)
    }

    @Test func skipsAlbumsThatITunesAlreadyPutThere() {
        let dup = makeDesired(makeSong("f", album: "foreign album!", albumId: "al-f", artist: "Foreign Artist"))
        let new = makeDesired(makeSong("a"))
        let plan = SyncPlanner.plan(fixture(songs: [dup, new], present: [],
                                            playlists: [DesiredPlaylist(id: "p", name: "Mix", songIDs: ["f", "a"])]))
        #expect(plan.add.map(\.id) == ["a"])
        #expect(plan.skippedForeignAlbums == ["al-f": "foreign album!"])
        #expect(plan.playlistsToCreate.count == 1)
    }

    @Test func duplicateDesiredSongsCountOnce() {
        let d = makeDesired(makeSong("a"))
        #expect(SyncPlanner.plan(fixture(songs: [d, d], present: [])).add.count == 1)
    }

    @Test func nothingToDoWhenEqual() {
        let d = makeDesired(makeSong("a"))
        let plan = SyncPlanner.plan(fixture(songs: [d], present: [d]))
        #expect(plan.isEmpty)
        #expect(plan.freedBytes == 0 && plan.addBytes == 0)
    }

    @Test func keepsSongsThatAreNoLongerSelected() {
        let a = makeDesired(makeSong("a")), b = makeDesired(makeSong("b"))
        let plan = SyncPlanner.plan(fixture(songs: [a], present: [a, b]))
        #expect(plan.isEmpty && plan.freedBytes == 0)
    }

    @Test func emptySelectionKeepsEverything() {
        let a = makeDesired(makeSong("a")), b = makeDesired(makeSong("b"))
        #expect(SyncPlanner.plan(fixture(songs: [], present: [a, b])).isEmpty)
    }

    @Test func staleManifestEntryIsReaddedNotRemoved() {
        let a = makeDesired(makeSong("a")), ghost = makeDesired(makeSong("ghost"))
        let input = fixture(songs: [a], present: [a]) { m in m.entries["ghost"] = makeEntry(ghost, dbid: 99_999, trackID: 99) }
        var again = input
        again.desired = [a, ghost]
        #expect(SyncPlanner.plan(input).remove.isEmpty)
        #expect(SyncPlanner.plan(again).add.map(\.id) == ["ghost"])
    }

    @Test func reencodeWhenPresetVersionChanges() {
        let old = makeDesired(makeSong("a"))
        var preset = Preset.stockAAC
        preset.version = 2
        let new = makeDesired(makeSong("a"), preset: preset)
        let plan = SyncPlanner.plan(fixture(songs: [new], present: [old]))
        #expect(plan.reencode.map(\.desired.id) == ["a"])
        #expect(plan.add.isEmpty && plan.remove.isEmpty && plan.retag.isEmpty)
        #expect(plan.freedBytes == 5_000_000)
    }

    @Test(arguments: [("size", 1), ("suffix", 2), ("created", 3)])
    func reencodeWhenSourceChanges(kind: String, _: Int) {
        let old = makeDesired(makeSong("a"))
        let song: Song = switch kind {
        case "size": makeSong("a", size: 31_000_000)
        case "suffix": makeSong("a", suffix: "wav")
        default: makeSong("a", created: "2025-01-01T00:00:00Z")
        }
        #expect(SyncPlanner.plan(fixture(songs: [makeDesired(song)], present: [old])).reencode.count == 1)
    }

    @Test func retagWhenOnlyMetadataChanges() {
        let old = makeDesired(makeSong("a"))
        let new = makeDesired(makeSong("a"), title: "Renamed")
        let plan = SyncPlanner.plan(fixture(songs: [new], present: [old]))
        #expect(plan.retag.map(\.desired.id) == ["a"])
        #expect(plan.reencode.isEmpty && plan.add.isEmpty)
    }

    @Test func soundCheckSettingTriggersRetag() {
        let old = makeDesired(makeSong("a"), gain: nil)
        let new = makeDesired(makeSong("a"), gain: -6.5)
        #expect(SyncPlanner.plan(fixture(songs: [new], present: [old])).retag.count == 1)
    }

    @Test func switchingToRockboxMovesTheSong() {
        let old = makeDesired(makeSong("a"))
        let new = makeDesired(makeSong("a"), preset: .rockboxOpus)
        let plan = SyncPlanner.plan(fixture(songs: [new], present: [old]))
        #expect(plan.remove.map(\.songID) == ["a"] && plan.remove[0].target == .stock)
        #expect(plan.add.map(\.id) == ["a"])
        #expect(plan.touchesStock)
    }

    @Test func rockboxMetadataChangeRewritesTheFile() {
        let old = makeDesired(makeSong("a"), preset: .rockboxOpus)
        let new = makeDesired(makeSong("a"), preset: .rockboxOpus, title: "Renamed")
        var manifest = Manifest(serverKey: "s")
        manifest.rockboxEntries["a"] = makeEntry(old, dbid: 0, trackID: 0, path: "Music/A/B/01-01 - x.opus")
        let input = PlannerInput(desired: [new], manifest: manifest,
                                 library: makeLibrary(manifest: manifest, rockbox: ["Music/A/B/01-01 - x.opus"]), freeBytes: free)
        let plan = SyncPlanner.plan(input)
        #expect(plan.reencode.count == 1 && plan.retag.isEmpty)
        #expect(!plan.touchesStock)
    }

    @Test func missingRockboxFileIsAddedAgain() {
        let d = makeDesired(makeSong("a"), preset: .rockboxOpus)
        var manifest = Manifest(serverKey: "s")
        manifest.rockboxEntries["a"] = makeEntry(d, dbid: 0, trackID: 0, path: "Music/gone.opus")
        let plan = SyncPlanner.plan(PlannerInput(desired: [d], manifest: manifest, library: makeLibrary(manifest: manifest), freeBytes: free))
        #expect(plan.add.count == 1)
    }

    @Test func spaceCheckKeepsFiveHundredMegabytesFree() {
        let d = makeDesired(makeSong("a", size: 400_000_000, suffix: "mp3", bitRate: 320))
        var input = fixture(songs: [d], present: [])
        input.freeBytes = 800_000_000
        #expect(!SyncPlanner.plan(input).fits)
        input.freeBytes = 900_000_001
        #expect(SyncPlanner.plan(input).fits)
    }

    @Test func freedSpaceCountsTowardsFitting() {
        let old = makeDesired(makeSong("a"))
        var preset = Preset.stockAAC
        preset.version = 2
        var input = fixture(songs: [makeDesired(makeSong("a"), preset: preset)], present: [old]) { m in m.entries["a"]?.outSize = 400_000_000 }
        input.freeBytes = 400_000_000
        let plan = SyncPlanner.plan(input)
        #expect(plan.reencode.count == 1 && plan.fits)
    }

    @Test func playlistsAreCreatedAndUpdatedButNeverDeleted() {
        let a = makeDesired(makeSong("a")), b = makeDesired(makeSong("b"))
        var input = fixture(songs: [a, b], present: [a, b], playlists: [
            DesiredPlaylist(id: "p-new", name: "New", songIDs: ["a"]),
            DesiredPlaylist(id: "p-same", name: "Same", songIDs: ["a", "b"]),
            DesiredPlaylist(id: "p-order", name: "Order", songIDs: ["b", "a"]),
        ]) { m in
            m.playlists = ["p-same": 11, "p-order": 12, "p-gone": 13]
        }
        let trackIDs = input.manifest.entries.mapValues(\.trackID)
        input.library = makeLibrary(
            tracks: [makeTrack(1)] + [a, b].enumerated().map { i, _ in makeTrack(10 + i, dbid: UInt64(500 + i)) },
            playlists: [PodPlaylist(persistentID: 11, name: "Same", trackIDs: [trackIDs["a"]!, trackIDs["b"]!]),
                        PodPlaylist(persistentID: 12, name: "Order", trackIDs: [trackIDs["a"]!, trackIDs["b"]!]),
                        PodPlaylist(persistentID: 13, name: "Gone", trackIDs: [])],
            manifest: input.manifest)
        let plan = SyncPlanner.plan(input)
        #expect(plan.playlistsToCreate.map(\.id) == ["p-new"])
        #expect(plan.playlistsToUpdate.map(\.id) == ["p-order"])
        #expect(plan.playlistsToDelete.isEmpty)
    }

    @Test func coversAreCollectedPerAlbum() {
        let a = makeDesired(makeSong("a", albumId: "x")), b = makeDesired(makeSong("b", albumId: "y"))
        #expect(SyncPlanner.plan(fixture(songs: [a, b], present: [])).albumCovers == ["x": "cov-x", "y": "cov-y"])
    }
}
