import Foundation
import Preferences
import Testing

private func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite struct AppearanceTests {
    @Test func oldSettingsKeepDefaults() throws {
        let empty: AppearanceSettings = try decode("{}")
        #expect(empty == AppearanceSettings())
        let some: AppearanceSettings = try decode(#"{"accent":"blue","density":"huge","songColumns":["plays","stars"]}"#)
        #expect(some.accent == .blue)
        #expect(some.density == .medium)  // unknown value: default
        #expect(some.songColumns == [.plays])
        #expect(some.startPage == .home)
    }

    @Test func savesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "prefs-test-\(UUID().uuidString)"))
        #expect(AppearanceSettings.load(from: defaults) == AppearanceSettings())
        var settings = AppearanceSettings()
        settings.accent = .graphite
        settings.density = .large
        settings.setShown("radio", false)
        settings.songColumns = [.format, .rating]
        settings.save(to: defaults)
        #expect(AppearanceSettings.load(from: defaults) == settings)
    }

    @Test func accentDefaultsToAppleMusicRed() {
        #expect(AppearanceSettings().accent == .red)
        let red = AppearanceSettings.Accent.red.rgb
        #expect(red.red > 0.9 && red.green < 0.2)
        #expect(Set(AppearanceSettings.Accent.allCases.map { "\($0.rgb)" }).count == AppearanceSettings.Accent.allCases.count)
    }

    @Test func gridDensityGrows() {
        let widths = AppearanceSettings.GridDensity.allCases.map(\.cardWidth.lowerBound)
        #expect(widths == widths.sorted() && Set(widths).count == 3)
    }

    @Test func sidebarVisibility() {
        var settings = AppearanceSettings()
        #expect(settings.shows("genres"))
        settings.setShown("genres", false)
        #expect(!settings.shows("genres"))
        #expect(settings.shows("albums"))
        settings.setShown("genres", true)
        #expect(settings.hiddenSidebarItems.isEmpty)
    }

    @Test func startPage() {
        #expect(AppearanceSettings.StartPage.albums.key(last: "songs") == "albums")
        #expect(AppearanceSettings.StartPage.last.key(last: "songs") == "songs")
        #expect(AppearanceSettings.StartPage.last.key(last: nil) == "home")
    }

    @Test func songColumns() {
        typealias C = AppearanceSettings.SongColumn
        #expect(C.detail([], rating: 4, plays: 3, suffix: "flac", bitRate: 900) == nil)
        #expect(C.detail([.plays], rating: 4, plays: 1, suffix: "flac", bitRate: 900) == "1 play")
        #expect(C.detail(Set(C.allCases), rating: 4, plays: 3, suffix: "flac", bitRate: 900) == "★★★★ · 3 plays · FLAC 900 kbps")
        #expect(C.detail(Set(C.allCases), rating: 0, plays: 0, suffix: "mp3", bitRate: nil) == "MP3")
    }
}

@Suite struct HomeSettingsTests {
    @Test func defaultOrder() {
        #expect(HomeSettings().visible == [.topPicks, .madeForYou, .because, .recentlyPlayed, .mostPlayed, .discover])
    }

    @Test func hideAndMove() {
        var home = HomeSettings()
        home.setShown(.madeForYou, false)
        home.move(.discover, by: -10)
        home.move(.topPicks, by: 1)
        #expect(home.visible == [.discover, .topPicks, .because, .recentlyPlayed, .mostPlayed])
        home.move(.mostPlayed, by: 5)
        #expect(home.order.last == .mostPlayed)
    }

    @Test func decodingKeepsEveryShelfOnce() throws {
        let home: HomeSettings = try decode(#"{"order":["discover","nope","discover","mostPlayed"],"hidden":["because","gone"]}"#)
        #expect(home.order == [.discover, .mostPlayed, .topPicks, .madeForYou, .because, .recentlyPlayed])
        #expect(home.hidden == [.because])
        let empty: HomeSettings = try decode("{}")
        #expect(empty == HomeSettings())
    }

    @Test func savesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "prefs-test-\(UUID().uuidString)"))
        var home = HomeSettings()
        home.move(.recentlyPlayed, by: -3)
        home.setShown(.discover, false)
        home.save(to: defaults)
        #expect(HomeSettings.load(from: defaults) == home)
    }
}

@Suite struct OtherSettingsTests {
    @Test func listeningDefaults() throws {
        let old: ListeningSettings = try decode(#"{"playsSource":"server"}"#)
        #expect(old.scrobble)
        #expect(!old.usesHistory)
        #expect(ListeningSettings().usesHistory)
    }

    @Test func advanced() throws {
        let old: AdvancedSettings = try decode(#"{"coverCacheMB":0}"#)
        #expect(old.requestTimeout == 30)
        #expect(old.coverCacheBytes == nil)
        #expect(AdvancedSettings().coverCacheBytes == 500_000_000)
        var settings = AdvancedSettings()
        settings.requestTimeout = 60
        #expect(settings.session().configuration.timeoutIntervalForRequest == 60)
    }

    @Test func search() {
        #expect(SettingsSearch.matches("", title: "Sync", keywords: []))
        #expect(SettingsSearch.matches("sound check", title: "Sync", keywords: ["Sound Check", "iPod"]))
        #expect(SettingsSearch.matches("ACCENT", title: "Appearance", keywords: ["accent color"]))
        #expect(!SettingsSearch.matches("accent", title: "Sync", keywords: ["iPod"]))
    }

    @Test func resetKeepsChosenAndSystemKeys() throws {
        let defaults = try #require(UserDefaults(suiteName: "prefs-test-\(UUID().uuidString)"))
        defaults.set(1, forKey: "syncSettings")
        defaults.set(2, forKey: "serverConfig")
        defaults.set(3, forKey: "NSWindow Frame Main")
        SettingsReset.reset(defaults, keeping: ["serverConfig"])
        #expect(defaults.object(forKey: "syncSettings") == nil)
        #expect(defaults.integer(forKey: "serverConfig") == 2)
        #expect(defaults.integer(forKey: "NSWindow Frame Main") == 3)
    }
}
