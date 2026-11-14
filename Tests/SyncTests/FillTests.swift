import Foundation
import Testing
@testable import Subsonic
@testable import Sync
@testable import Transcode

/// Favorites and "fill with the most played albums" of a device selection.
@Suite struct FillTests {
    @Test func oldSelectionsKeepTodaysBehaviour() throws {
        let old = try JSONDecoder().decode(Selection.self, from: Data(#"{"albums":["al-1"]}"#.utf8))
        #expect(!old.favorites && !old.fillMostPlayed)
        var selection = Selection()
        #expect(selection.isEmpty)
        selection.favorites = true
        #expect(!selection.isEmpty)
        #expect(try JSONDecoder().decode(Selection.self, from: JSONEncoder().encode(selection)) == selection)
    }

    @Test func expandsFavoritesAndFillers() async throws {
        let s = StubServer()
        let file = URL(fileURLWithPath: "/nonexistent")
        func song(_ id: String, _ album: String) -> [String: Any] {
            songJSON(id, title: id, track: 1, album: album, albumId: album, file: file, seconds: 100)
        }
        s.reply("getAlbum:al-1", StubServer.albumReply(albumJSON(id: "al-1", name: "al-1", songs: [song("a1", "al-1"), song("a2", "al-1")])))
        s.reply("getAlbum:al-2", StubServer.albumReply(albumJSON(id: "al-2", name: "al-2", songs: [song("b1", "al-2")])))
        s.reply("getStarred2", StubServer.reply(["starred2": ["song": [song("a2", "al-1")]]]))
        s.reply("getAlbumList2", StubServer.reply(["albumList2": ["album": [["id": "al-2", "name": "al-2"], ["id": "al-1", "name": "al-1"]]]]))
        var selection = Selection()
        let none = try await SelectionExpander(client: s.client).expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        #expect(none.songs.isEmpty && none.fillers.isEmpty && none.playlists.isEmpty)

        selection.favorites = true
        selection.fillMostPlayed = true
        let result = try await SelectionExpander(client: s.client).expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        #expect(result.songs.map(\.id) == ["a2"])
        #expect(result.songs.first?.tags.trackTotal == 2)  // its album was read for the totals
        #expect(result.playlists == [DesiredPlaylist(id: SelectionExpander.favoritesID, name: "Favorites", songIDs: ["a2"])])
        #expect(result.fillers.map(\.id) == ["b1", "a1", "a2"])  // most played album first
    }

    @Test func fillsWholeAlbumsThatFit() {
        // FLAC to AAC 256k: 100 s are about 3.3 MB.
        let big = (1...3).map { makeDesired(makeSong("b\($0)", albumId: "al-big", duration: 100)) }
        let small = [makeDesired(makeSong("s1", albumId: "al-small", duration: 100))]
        let wanted = makeDesired(makeSong("w", albumId: "al-w", duration: 100))
        func plan(free: Int64) -> SyncPlan {
            let manifest = Manifest(serverKey: "s")
            return SyncPlanner.plan(PlannerInput(desired: [wanted], manifest: manifest, library: makeLibrary(tracks: [], manifest: manifest),
                                                 freeBytes: free, reserveBytes: 1_000_000, fillers: big + small + [wanted]))
        }
        let roomy = plan(free: 100_000_000)
        #expect(roomy.add.map(\.id) == ["w", "b1", "b2", "b3", "s1"] && roomy.filledSongs == 4 && roomy.fits)
        // Room for the wanted song and one more small album: the big one is skipped, the small one still fits.
        let tight = plan(free: 9_000_000)
        #expect(tight.add.map(\.id) == ["w", "s1"] && tight.filledSongs == 1 && tight.fits)
        let full = plan(free: 4_000_000)
        #expect(full.add.map(\.id) == ["w"] && full.filledSongs == 0)
        #expect(SyncPlanner.plan(PlannerInput(desired: [wanted], manifest: Manifest(serverKey: "s"),
                                              library: makeLibrary(tracks: [], manifest: Manifest(serverKey: "s")),
                                              freeBytes: 100_000_000)).filledSongs == 0)
    }
}
