import Foundation
import Testing
@testable import Subsonic

@Suite struct MusicVideoTests {
    private func songs(_ json: String) throws -> [Song] { try JSONDecoder().decode([Song].self, from: Data(json.utf8)) }

    @Test func matchesTitleAndArtist() throws {
        let song = try songs(#"[{"id":"s","title":"Héroes","artist":"David Bowie"}]"#)[0]
        let videos = try songs(#"""
            [{"id":"v1","title":"Heroes (Live)","artist":"Someone Else"},
             {"id":"v2","title":"David Bowie - HEROES (Official Video)"},
             {"id":"v3","title":"Heroes","artist":"David Bowie"}]
            """#)
        #expect(MusicVideo.match(song, in: videos)?.id == "v2")
        #expect(MusicVideo.match(song, in: [videos[0]]) == nil)
        #expect(MusicVideo.match(song, in: [videos[2]])?.id == "v3")
    }

    @Test func readsFastsideRedirect() throws {
        let reply = Data(#"{"url":"https://inv.example/results?q=x","is_fallback":false}"#.utf8)
        #expect(try MusicVideoFinder.decodeRedirect(reply).absoluteString == "https://inv.example/")
        let fallback = Data(#"{"url":"https://www.youtube.com/","is_fallback":true}"#.utf8)
        #expect(throws: SubsonicError.self) { try MusicVideoFinder.decodeRedirect(fallback) }
        #expect((try? JSONSerialization.jsonObject(with: Data(MusicVideoFinder.config.utf8))) != nil)
    }

    @Test func readsPipedAPIHost() throws {
        let script = Data("function $(){return Z(`instance`,`https://pipedapi.example`)}function we(){}".utf8)
        #expect(try MusicVideoFinder.pipedAPI(script).absoluteString == "https://pipedapi.example")
        #expect(throws: SubsonicError.self) { try MusicVideoFinder.pipedAPI(Data("nothing".utf8)) }
    }

    @Test func picksTheArtistsVideo() throws {
        let invidious = try MusicVideoFinder.decodeInvidious(Data(#"""
            [{"type":"channel","author":"Кино"},
             {"type":"video","videoId":"topic000000","title":"Группа крови","author":"Кино - Topic"},
             {"type":"video","videoId":"cover000000","title":"Группа крови (cover)","author":"Someone"},
             {"type":"video","videoId":"xtxjm7ciwmc","title":"Группа крови","author":"Группа КИНО"}]
            """#.utf8))
        #expect(invidious.map(\.id) == ["topic000000", "cover000000", "xtxjm7ciwmc"])
        #expect(MusicVideoFinder.pick(invidious, artist: "Кино", title: "Группа крови") == "xtxjm7ciwmc")
        #expect(MusicVideoFinder.pick(invidious, artist: "Other", title: "Группа крови") == nil)
        let piped = try MusicVideoFinder.decodePiped(Data(#"""
            {"items":[{"type":"channel","url":"/channel/x"},
                      {"type":"stream","url":"/watch?v=lXgkuM2NhYI","title":"David Bowie - \"Heroes\" (Official Video)","uploaderName":"David Bowie"}]}
            """#.utf8))
        #expect(piped.map(\.id) == ["lXgkuM2NhYI"])
        #expect(MusicVideoFinder.pick(piped, artist: "David Bowie", title: "Heroes") == "lXgkuM2NhYI")
    }

    @Test func adRulesAreValidContentBlockerJSON() throws {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(YouTubeAdBlock.rules.utf8)) as? [[String: [String: String]]])
        #expect(rules.count == YouTubeAdBlock.blocked.count)
        #expect(rules.allSatisfy { $0["action"]?["type"] == "block" && $0["trigger"]?["url-filter"] != nil })
        for host in ["doubleclick", "googlesyndication", "pagead", "ctier=L"] {
            #expect(YouTubeAdBlock.blocked.contains { $0.contains(host) }, "\(host)")
        }
    }
}
