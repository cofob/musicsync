import Carbon.HIToolbox
import Foundation
import Subsonic
import Testing
@testable import Integration

@Suite struct DeepLinkTests {
    private func link(_ s: String) -> DeepLink? { URL(string: s).flatMap(DeepLink.init(url:)) }

    @Test func parsesEveryForm() {
        #expect(link("musicsync://album/al-1") == .show(.album, id: "al-1"))
        #expect(link("musicsync://artist/ar-1") == .show(.artist, id: "ar-1"))
        #expect(link("musicsync://playlist/pl-1/") == .show(.playlist, id: "pl-1"))
        #expect(link("MusicSync://Song/s-1") == .show(.song, id: "s-1"))
        #expect(link("musicsync://play/album/al-1") == .play(.album, id: "al-1"))
        #expect(link("musicsync://play/song/s-1") == .play(.song, id: "s-1"))
        #expect(link("musicsync://search?q=Aphex%20Twin") == .search("Aphex Twin"))
        #expect(link("musicsync://search") == .search(""))
        #expect(link("musicsync://command/next") == .command(.next))
        #expect(link("musicsync://command/TOGGLE") == .command(.toggle))
    }

    @Test func rejectsOthers() {
        for s in ["https://album/al-1", "musicsync://album", "musicsync://album/a/b", "musicsync://genre/x",
                  "musicsync://play/genre/x", "musicsync://play/album", "musicsync://command/stop", "musicsync://command",
                  "musicsync://search/x", "musicsync:album/al-1"] {
            #expect(link(s) == nil, "\(s)")
        }
    }

    @Test func roundTripsOddIds() throws {
        let links: [DeepLink] = [.show(.album, id: "a/b c?#%é"), .play(.playlist, id: "x/y"), .search("a&b=c d"), .command(.favorite)]
        for l in links {
            #expect(DeepLink(url: l.url) == l, "\(l.url)")
        }
        #expect(DeepLink.show(.album, id: "al-1").url.absoluteString == "musicsync://album/al-1")
        #expect(DeepLink.play(.artist, id: "ar 1").url.absoluteString == "musicsync://play/artist/ar%201")
    }
}

@Suite struct ShareTargetTests {
    @Test func textWithAndWithoutPublicLink() throws {
        let target = ShareTarget(kind: .album, id: "al-1", title: "Selected Ambient Works", artist: "Aphex Twin")
        #expect(target.label == "Selected Ambient Works — Aphex Twin")
        #expect(target.text() == "Selected Ambient Works — Aphex Twin\nmusicsync://album/al-1")
        let link = try #require(URL(string: "https://music.example.com/share/xyz"))
        #expect(target.text(link: link) == "Selected Ambient Works — Aphex Twin\nhttps://music.example.com/share/xyz")
        #expect(ShareTarget(kind: .playlist, id: "p", title: "Mix", artist: "").label == "Mix")
        let song: Song = try decode(#"{"id":"s-1","title":"Xtal","artist":"AFX","displayArtist":"Aphex Twin","coverArt":"c-1"}"#)
        #expect(ShareTarget(song: song) == ShareTarget(kind: .song, id: "s-1", title: "Xtal", artist: "Aphex Twin", coverArt: "c-1"))
    }
}

private func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }

@Suite struct SpotlightTests {
    private let artist: Artist = try! decode(#"{"id":"ar-1","name":"Aphex Twin","coverArt":"c-ar"}"#)
    private let album: Album = try! decode(#"{"id":"al-1","name":"SAW","artist":"Aphex Twin","year":1992,"coverArt":"c-al"}"#)
    private let playlist: Playlist = try! decode(#"{"id":"pl-1","name":"Mix"}"#)

    @Test func buildsEntriesAndItems() {
        let entries = SpotlightEntry.entries(artists: [artist], albums: [album], playlists: [playlist],
                                             thumbnails: ["c-al": URL(fileURLWithPath: "/tmp/c-al.jpg")])
        #expect(entries.map(\.id) == ["musicsync://artist/ar-1", "musicsync://album/al-1", "musicsync://playlist/pl-1"])
        #expect(entries[1].subtitle == "Album · Aphex Twin · 1992")
        #expect(entries[1].thumbnail == "/tmp/c-al.jpg" && entries[0].thumbnail == nil)
        let item = entries[1].searchableItem
        #expect(item.uniqueIdentifier == "musicsync://album/al-1")
        #expect(item.domainIdentifier == "album")
        #expect(item.attributeSet.title == "SAW")
        #expect(item.attributeSet.thumbnailURL?.path == "/tmp/c-al.jpg")
        #expect(DeepLink(url: URL(string: item.uniqueIdentifier)!) == .show(.album, id: "al-1"))
    }

    @Test func planSendsOnlyChanges() {
        let a = SpotlightEntry(kind: .album, itemId: "1", title: "A", subtitle: nil, thumbnail: nil)
        let b = SpotlightEntry(kind: .album, itemId: "2", title: "B", subtitle: nil, thumbnail: nil)
        let b2 = SpotlightEntry(kind: .album, itemId: "2", title: "B", subtitle: nil, thumbnail: "/t.jpg")
        let c = SpotlightEntry(kind: .artist, itemId: "3", title: "C", subtitle: nil, thumbnail: nil)
        let plan = SpotlightPlan(old: [a.id: a, b.id: b], new: [b2, c])
        #expect(plan.upserts == [b2, c])
        #expect(plan.removals == [a.id])
        #expect(SpotlightPlan(old: [a.id: a], new: [a]) == SpotlightPlan(old: [:], new: []))
    }

    @Test func indexerIsIncrementalAndPerServer() async throws {
        let sink = RecordingSink()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("spotlight-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: state) }
        let a = SpotlightEntry(kind: .album, itemId: "1", title: "A", subtitle: nil, thumbnail: nil)
        let b = SpotlightEntry(kind: .album, itemId: "2", title: "B", subtitle: nil, thumbnail: nil)

        try await SpotlightIndexer(sink: sink, stateURL: state).update(serverKey: "s1", entries: [a, b])
        // A new indexer reads the saved state: nothing is sent again.
        let indexer = SpotlightIndexer(sink: sink, stateURL: state)
        try await indexer.update(serverKey: "s1", entries: [a, b])
        try await indexer.update(serverKey: "s1", entries: [a])
        try await indexer.use(serverKey: "s1")
        try await indexer.update(serverKey: "s2", entries: [a])
        try await indexer.use(serverKey: nil)
        try await indexer.use(serverKey: nil)
        #expect(sink.calls == ["index 1,2", "delete 2", "deleteAll", "index 1", "deleteAll"])
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }
}

private final class RecordingSink: SpotlightSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    private func add(_ s: String) { lock.withLock { _calls.append(s) } }

    func index(_ entries: [SpotlightEntry]) async throws {
        add("index " + entries.map { $0.id.components(separatedBy: "/").last ?? "" }.sorted().joined(separator: ","))
    }
    func delete(ids: [String]) async throws { add("delete " + ids.map { $0.components(separatedBy: "/").last ?? "" }.joined(separator: ",")) }
    func deleteAll() async throws { add("deleteAll") }
}

@Suite struct HotKeyTests {
    @Test func comboFromEvent() {
        let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_P), flags: [.control, .option, .command], characters: "p")
        #expect(combo.display == "⌃⌥⌘P")
        #expect(combo.modifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(combo.isValid)
        #expect(KeyCombo(keyCode: UInt16(kVK_RightArrow), flags: [.command, .shift], characters: "").display == "⇧⌘→")
        #expect(KeyCombo(keyCode: UInt16(kVK_F5), flags: [], characters: "").display == "F5")
        #expect(KeyCombo(keyCode: UInt16(kVK_F5), flags: [], characters: "").isValid)
        #expect(!KeyCombo(keyCode: UInt16(kVK_ANSI_P), flags: [.shift], characters: "p").isValid)
        #expect(!KeyCombo(keyCode: UInt16(kVK_ANSI_P), flags: [], characters: "p").isValid)
    }

    @Test func oneComboPerActionAndCoding() throws {
        let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_P), flags: [.command, .option], characters: "p")
        var settings = HotKeySettings()
        #expect(!settings.enabled)
        #expect(settings.assign(combo, to: .playPause) == nil)
        #expect(settings.assign(combo, to: .next) == .playPause)
        #expect(settings.combos == [.next: combo])
        #expect(settings.assign(combo, to: .next) == nil)
        settings.assign(nil, to: .next)
        #expect(settings.combos.isEmpty)
        settings.assign(combo, to: .volumeUp)
        let data = try JSONEncoder().encode(settings)
        #expect(String(decoding: data, as: UTF8.self).contains(#""volumeUp""#))
        #expect(try JSONDecoder().decode(HotKeySettings.self, from: data) == settings)
    }

    /// Registers a combo nobody uses for a moment: the second exclusive registration must fail.
    @MainActor @Test func registrationAndConflict() {
        let combo = KeyCombo(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), key: "F19")
        let first = HotKeyCenter { _ in }, second = HotKeyCenter { _ in }
        defer { first.stop(); second.stop() }
        #expect(first.register([.next: combo]).isEmpty)
        #expect(second.register([.previous: combo]) == [.previous])
        first.unregisterAll()
        #expect(second.register([.previous: combo]).isEmpty)
    }
}
