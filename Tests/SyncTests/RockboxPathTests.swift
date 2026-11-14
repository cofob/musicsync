import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Sync
@testable import Transcode

@Suite struct RockboxPathTests {
    @Test func forbiddenCharactersAndEdgesAreCleaned() {
        #expect(RockboxPaths.component("AC/DC: Live?") == "AC_DC_ Live_")
        #expect(RockboxPaths.component(#"a\b*c"d<e>f|g"#) == "a_b_c_d_e_f_g")
        #expect(RockboxPaths.component("  ...Name. . ") == "Name")
        #expect(RockboxPaths.component("...", fallback: "Unknown") == "Unknown")
        #expect(RockboxPaths.component("") == "_")
        #expect(RockboxPaths.component("tab\there") == "tab_here")
    }

    @Test func componentsStayWithinByteLimitOnCharacterBoundaries() {
        let long = String(repeating: "日", count: 200)
        let cut = RockboxPaths.component(long)
        #expect(cut.utf8.count == 255 && cut.count == 85)
        let path = RockboxPaths.songPath(TrackTags(title: long, artist: "A", album: "B"), ext: "opus")
        let name = path.split(separator: "/").last!
        #expect(name.utf8.count <= 255 && name.hasSuffix(".opus"))
        #expect(RockboxPaths.component("x. ", maxBytes: 5) == "x")
    }

    @Test func songPathLayout() {
        let tags = TrackTags(title: "Intro / Outro", artist: "Solo", album: "The Album", albumArtist: "Band",
                             year: 1999, trackNumber: 3, discNumber: 2)
        #expect(RockboxPaths.songPath(tags, ext: "flac") == "Music/Band/1999 - The Album/02-03 - Intro _ Outro.flac")
        let bare = TrackTags(title: "T", artist: "Solo", album: "")
        #expect(RockboxPaths.songPath(bare, ext: "opus") == "Music/Solo/Unknown Album/01-00 - T.opus")
    }

    @Test func playlistFiles() {
        #expect(RockboxPaths.playlistPath("Road/Trip") == "Playlists/Road_Trip.m3u8")
        #expect(RockboxPaths.playlistContents(["Music/A/B/c.opus"]) == "#EXTM3U\n../Music/A/B/c.opus\n")
    }

    @Test func coverIsBaselineJPEGOf500Pixels() throws {
        let jpeg = try #require(RockboxPaths.coverJPEG(from: makeCoverPNG(size: 640)))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(jpeg.range(of: Data([0xFF, 0xC0])) != nil)  // baseline frame header
        #expect(jpeg.range(of: Data([0xFF, 0xC2])) == nil)  // no progressive
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 500 && image.height == 500)
        #expect(RockboxPaths.coverJPEG(from: Data("nope".utf8)) == nil)
    }
}
