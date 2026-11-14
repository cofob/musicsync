import Foundation
import Testing
@testable import Subsonic
@testable import Sync
@testable import Transcode

@Suite struct ExpanderTests {
    func server() -> StubServer {
        let s = StubServer()
        let file = URL(fileURLWithPath: "/nonexistent")
        func song(_ id: String, _ album: String, track: Int, disc: Int, title: String? = nil) -> [String: Any] {
            songJSON(id, title: title ?? id, track: track, album: album, albumId: album, file: file, seconds: 100,
                     extra: ["discNumber": disc, "replayGain": ["albumGain": -3.0, "trackGain": -5.0]])
        }
        s.reply("getAlbum:al-1", StubServer.albumReply(albumJSON(id: "al-1", name: "al-1", songs: [
            song("a1", "al-1", track: 1, disc: 1), song("a2", "al-1", track: 2, disc: 1),
            song("a3", "al-1", track: 1, disc: 2),
        ])))
        s.reply("getAlbum:al-2", StubServer.albumReply(albumJSON(id: "al-2", name: "al-2", songs: [song("b1", "al-2", track: 1, disc: 1)])))
        s.reply("getAlbum:al-3", StubServer.albumReply(albumJSON(id: "al-3", name: "al-3", songs: [song("c1", "al-3", track: 1, disc: 1)])))
        s.reply("getArtist:ar-1", StubServer.reply(["artist": ["id": "ar-1", "name": "Artist", "album": [["id": "al-2", "name": "al-2"], ["id": "al-3", "name": "al-3"]]]]))
        s.reply("getPlaylist:pl-1", StubServer.reply(["playlist": ["id": "pl-1", "name": "Mix", "entry": [
            song("c1", "al-3", track: 1, disc: 1), song("a1", "al-1", track: 1, disc: 1),
        ]]]))
        return s
    }

    @Test func expandsAlbumsArtistsAndPlaylistsWithTotals() async throws {
        let s = server()
        var selection = Selection()
        selection.albums = ["al-1"]
        selection.artists = ["ar-1"]
        selection.playlists = ["pl-1"]
        selection.albumPresets = ["al-3": "rockbox-opus"]
        let result = try await SelectionExpander(client: s.client).expand(selection, defaultPresetID: "stock-aac", soundCheck: .album)

        #expect(result.songs.map(\.id) == ["a1", "a2", "a3", "b1", "c1"])  // each song once
        #expect(result.missing.isEmpty)
        let a2 = try #require(result.songs.first { $0.id == "a2" })
        #expect(a2.tags.trackNumber == 2 && a2.tags.trackTotal == 2 && a2.tags.discNumber == 1 && a2.tags.discTotal == 2)
        #expect(result.songs.first { $0.id == "a3" }?.tags.trackTotal == 1)
        #expect(a2.tags.albumArtist == "Test Artist" && a2.tags.year == 2020 && a2.coverArtID == "cov-al-1")
        #expect(a2.soundCheckGain == -3.0)
        #expect(result.songs.first { $0.id == "c1" }?.preset.id == "rockbox-opus")
        #expect(result.songs.first { $0.id == "b1" }?.preset.id == "stock-aac")
        #expect(result.playlists == [DesiredPlaylist(id: "pl-1", name: "Mix", songIDs: ["c1", "a1"])])
    }

    @Test func fullAlbumsModeBringsWholeAlbumsOfPlaylistSongs() async throws {
        var selection = Selection()
        selection.playlists = ["pl-1"]
        let plain = try await SelectionExpander(client: server().client).expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        #expect(plain.songs.map(\.id) == ["c1", "a1"])

        let full = try await SelectionExpander(client: server().client).expand(selection, defaultPresetID: "stock-aac", soundCheck: .off, fullAlbums: true)
        #expect(full.songs.map(\.id) == ["c1", "a1", "a2", "a3"])
        #expect(full.playlists.first?.songIDs == ["c1", "a1"])  // the iPod playlist keeps only its own songs
    }

    @Test func soundCheckSourceSelectsTheGain() async throws {
        var selection = Selection()
        selection.albums = ["al-2"]
        for (source, gain) in [(SyncSettings.SoundCheckSource.album, -3.0), (.track, -5.0), (.off, nil)] {
            let result = try await SelectionExpander(client: server().client).expand(selection, defaultPresetID: "stock-aac", soundCheck: source)
            #expect(result.songs.first?.soundCheckGain == gain)
        }
    }

    @Test func cachesAlbumsAcrossCalls() async throws {
        let s = server()
        var selection = Selection()
        selection.albums = ["al-1", "al-2"]
        let expander = SelectionExpander(client: s.client)
        _ = try await expander.expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        _ = try await expander.expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        #expect(s.requests.filter { $0 == "getAlbum" }.count == 2)
        await expander.clearCache()
        _ = try await expander.expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        #expect(s.requests.filter { $0 == "getAlbum" }.count == 4)
    }

    @Test func unknownServerIDsAreReportedMissing() async throws {
        var selection = Selection()
        selection.albums = ["al-2", "gone"]
        selection.playlists = ["gone-pl"]
        let result = try await SelectionExpander(client: server().client).expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        #expect(result.songs.map(\.id) == ["b1"] && Set(result.missing) == ["gone", "gone-pl"])
    }

    @Test func serverErrorsAbortInsteadOfLookingLikeDeletions() async {
        let s = server()
        s.reply("getAlbum:al-2", StubServer.reply([:]).replacingOccurrences(of: "\"ok\"", with: "\"failed\"")
            .replacingOccurrences(of: "\"version\"", with: "\"error\":{\"code\":0,\"message\":\"boom\"},\"version\""))
        var selection = Selection()
        selection.albums = ["al-2"]
        await #expect(throws: SubsonicError.self) {
            try await SelectionExpander(client: s.client).expand(selection, defaultPresetID: "stock-aac", soundCheck: .off)
        }
    }

    @Test func unknownPresetThrows() async {
        var selection = Selection()
        selection.albums = ["al-2"]
        await #expect(throws: ExpansionError.unknownPreset("nope")) {
            try await SelectionExpander(client: server().client).expand(selection, defaultPresetID: "nope", soundCheck: .off)
        }
    }
}

@Test func olderSettingsJSONStillLoads() throws {
    let old = #"{"presetID":"rockbox-flac","workers":3,"soundCheck":"track","ejectAfterSync":true,"manualGuids":{"U":"G"}}"#
    let s = try JSONDecoder().decode(SyncSettings.self, from: Data(old.utf8))
    #expect(s.presetID == "rockbox-flac" && s.workers == 3 && s.soundCheck == .track && s.ejectAfterSync)
    #expect(s.manualGuids == ["U": "G"] && !s.fullAlbums)
}
