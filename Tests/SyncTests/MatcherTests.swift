import Foundation
import Testing
import struct Subsonic.Album
import struct Subsonic.Song
@testable import ITunesDB
@testable import Sync
@testable import Transcode

private func makeAlbum(_ id: String, _ name: String, artist: String, artistId: String = "ar-1", songs: Int = 3) -> Album {
    let json: [String: Any] = ["id": id, "name": name, "artist": artist, "artistId": artistId, "songCount": songs]
    return try! JSONDecoder().decode(Album.self, from: JSONSerialization.data(withJSONObject: json))
}

@Suite struct NormalizerTests {
    @Test(arguments: [
        ("Björk", "bjork"), ("  The  Dark Side, Of the Moon!! ", "the dark side of the moon"),
        ("AC/DC", "ac dc"), ("Simon & Garfunkel", "simon and garfunkel"), ("ＡＢＣ", "abc"),
        ("Daft Punk (feat. Pharrell Williams)", "daft punk"), ("Song [ft. Someone] live", "song live"),
        ("Featherweight", "featherweight"), ("Naïve", "naive"),
    ])
    func keys(input: String, expected: String) {
        #expect(Normalizer.key(input) == expected)
    }
}

@Suite struct MatcherTests {
    /// Managed album "al-1" (2 of 3 tracks on the device), foreign "Bjork / Vespertine" (3 tracks), foreign single track.
    func fixture(presetID: String = "stock-aac", selection: Selection = Selection()) -> Matcher {
        var manifest = Manifest(serverKey: "s")
        var tracks: [Track] = []
        for i in 1...2 {
            tracks.append(makeTrack(i, album: "Managed", artist: "Me", dbid: UInt64(i)))
            var entry = makeEntry(makeDesired(makeSong("m\(i)", albumId: "al-1")), dbid: UInt64(i), trackID: UInt32(i))
            entry.presetID = presetID
            manifest.entries["m\(i)"] = entry
        }
        for i in 1...3 { tracks.append(makeTrack(10 + i, album: "Vespertine", artist: "Björk")) }
        tracks.append(makeTrack(20, album: "Lonely Hits", artist: "Solo"))
        let library = makeLibrary(tracks: tracks, manifest: manifest)
        return Matcher(library: library, manifest: manifest, selection: selection, defaultPresetID: "stock-aac")
    }

    @Test func managedAlbumIsPartialUntilComplete() {
        #expect(fixture().status(of: makeAlbum("al-1", "Managed", artist: "Me", songs: 3)) == .partial)
        #expect(fixture().status(of: makeAlbum("al-1", "Managed", artist: "Me", songs: 2)) == .synced)
    }

    @Test func pendingNeedsSelection() {
        let album = makeAlbum("al-9", "Brand New", artist: "Nobody")
        #expect(fixture().status(of: album) == .none)
        var selection = Selection()
        selection.albums = ["al-9"]
        #expect(fixture(selection: selection).status(of: album) == .pending)
        selection = Selection()
        selection.artists = ["ar-1"]
        #expect(fixture(selection: selection).status(of: album) == .pending)
    }

    @Test func oldPresetIsOutdatedOnlyWhenSelected() {
        let album = makeAlbum("al-1", "Managed", artist: "Me", songs: 2)
        var selection = Selection()
        selection.albums = ["al-1"]
        selection.albumPresets = ["al-1": "rockbox-opus"]
        #expect(fixture(selection: selection).status(of: album) == .outdated)
        #expect(fixture(presetID: "old-preset").status(of: album) == .synced)
    }

    @Test func foreignMatchIgnoresCaseAccentsAndPunctuation() {
        let m = fixture()
        #expect(m.status(of: makeAlbum("x", "VESPERTINE!", artist: "Bjork", songs: 3)) == .foreign)
        #expect(m.status(of: makeAlbum("x", "Vespertine", artist: "Björk (feat. Someone)", songs: 4)) == .foreign)
        #expect(m.status(of: makeAlbum("x", "Vespertine", artist: "Björk", songs: 20)) == .none)
        #expect(m.status(of: makeAlbum("x", "Homogenic", artist: "Björk", songs: 3)) == .none)
    }

    @Test func foreignBeatsPendingButManagedWins() {
        var selection = Selection()
        selection.albums = ["x"]
        #expect(fixture(selection: selection).status(of: makeAlbum("x", "Vespertine", artist: "Björk")) == .foreign)
    }

    @Test func managedTracksNeverMakeForeignAlbums() {
        #expect(fixture().status(of: makeAlbum("other", "Managed", artist: "Me", songs: 2)) == .none)
    }

    @Test func tenThousandAlbumsAreFast() {
        let m = fixture()
        let albums = (0..<10_000).map { makeAlbum("a\($0)", "Album \($0)", artist: "Artist \($0 % 500)") }
        let start = Date()
        let statuses = m.statuses(for: albums)
        #expect(statuses.count == 10_000)
        #expect(Date().timeIntervalSince(start) < 3)
    }
}
