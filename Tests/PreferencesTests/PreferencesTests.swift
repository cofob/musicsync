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

    @Test func accentDefaultsToRed() {
        #expect(AppearanceSettings().accent == .red)
        let red = AppearanceSettings.Accent.red.rgb
        #expect(red.red > 0.9 && red.green < 0.2)
        let fixed = AppearanceSettings.Accent.allCases.filter { $0 != .album }
        #expect(Set(fixed.map { "\($0.rgb)" }).count == fixed.count)
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

@Suite struct AppearanceLookTests {
    typealias Column = AppearanceSettings.SongsTableColumn

    @Test func defaults() {
        let settings = AppearanceSettings()
        #expect(settings.listDensity == .comfortable)
        #expect(settings.nowPlayingBackground == .animated)
        #expect(settings.tableColumns == Column.defaults)
    }

    @Test func olderSettingsLoad() throws {
        let old: AppearanceSettings = try decode(#"{"accent":"pink","nowPlayingBackground":"artwork"}"#)
        #expect(old.accent == .pink)
        #expect(old.nowPlayingBackground == .artwork)  // "Static" stays
        #expect(old.listDensity == .comfortable)
        #expect(old.tableColumns == Column.defaults)
        let odd: AppearanceSettings = try decode(#"{"accent":"album","listDensity":"tiny","tableColumns":["year","year","lyrics","plays"]}"#)
        #expect(odd.accent == .album)
        #expect(odd.listDensity == .comfortable)
        #expect(odd.tableColumns == [.title, .year, .plays])  // no duplicates or unknown columns; title kept
    }

    @Test func savesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "prefs-test-\(UUID().uuidString)"))
        var settings = AppearanceSettings()
        settings.accent = .album
        settings.listDensity = .compact
        settings.nowPlayingBackground = .plain
        settings.setTableColumns([.track, .title, .bitRate])
        settings.save(to: defaults)
        #expect(AppearanceSettings.load(from: defaults) == settings)
    }

    @Test func tableColumns() {
        var settings = AppearanceSettings()
        settings.setShown(.year, true)
        #expect(settings.tableColumns.last == .year)
        settings.setShown(.year, true)
        #expect(settings.tableColumns.filter { $0 == .year }.count == 1)
        settings.setShown(.genre, false)
        settings.setShown(.title, false)
        #expect(settings.shows(.title) && !settings.shows(.genre))
        settings.setTableColumns([.artist, .year])
        #expect(settings.tableColumns == [.title, .artist, .year])
        settings.setShown(.size, false, device: true)
        #expect(settings.deviceTableColumns == Array(Column.deviceDefaults.dropLast()) && settings.tableColumns == [.title, .artist, .year])
    }

    @Test func listDensity() {
        typealias D = AppearanceSettings.ListDensity
        #expect(D.compact.rowHeight(twoLines: false) < D.comfortable.rowHeight(twoLines: false))
        #expect(D.compact.rowHeight(twoLines: true) < D.comfortable.rowHeight(twoLines: true))
        #expect(D.compact.tableRowHeight < D.comfortable.tableRowHeight)
    }

    @Test func coverAccent() throws {
        typealias A = AppearanceSettings.Accent
        #expect(A.vivid([(0.5, 0.5, 0.5), (0.1, 0.1, 0.1)]) == nil)  // gray cover
        let blue = try #require(A.vivid([(0.4, 0.4, 0.4), (0.1, 0.2, 0.5), (0.3, 0.3, 0.32)]))
        #expect(blue.blue > blue.red && blue.blue > blue.green)
        #expect(max(blue.red, blue.green, blue.blue) >= 0.7)  // a dark cover still gives a readable color
        let red = try #require(A.vivid([(0.9, 0.1, 0.1)]))
        #expect(abs(red.red - 0.9) < 0.01 && abs(red.green - 0.1) < 0.01 && abs(red.blue - 0.1) < 0.01)
        #expect(A.album.rgb == A.red.rgb)
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
