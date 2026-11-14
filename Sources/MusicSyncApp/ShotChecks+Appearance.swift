import AppKit
import Preferences
import SwiftUI

/// `check:appearance`: each choice of Settings > Appearance reaches the views that use it.
extension ShotChecks {
    static func appearance(_ model: AppModel) async {
        let prefs = AppPreferences.shared
        defer { prefs.appearance = AppearanceSettings() }
        prefs.appearance = AppearanceSettings()
        await Shot.playPaused(model)
        await Shot.select(.songs, model)
        guard let (table, _) = await songs() else { return }
        let shown = { table.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue) }
        check(shown() == AppearanceSettings.SongsTableColumn.defaults.map(\.rawValue), "default columns: \(shown())")
        check(table.rowHeight == 24, "comfortable table rows: \(table.rowHeight)")

        // The header menu, as a Control-click opens it.
        let menu = table.headerView?.menu
        menu.map { $0.delegate?.menuNeedsUpdate?($0) }
        let year = menu?.items.first { $0.title == "Year" }
        check(year?.state == .off && menu?.items.first { $0.title == "Title" }?.isEnabled == false, "header menu: Year off, Title fixed")
        year.map { _ = ($0.target as? NSObject)?.perform($0.action, with: $0) }
        check(await wait { shown().last == "year" && prefs.appearance.shows(.year) }, "Year shows at the end: \(shown())")
        menu.map { $0.delegate?.menuNeedsUpdate?($0) }
        check(menu?.items.first { $0.title == "Year" }?.state == .on, "header menu checks Year")
        table.moveColumn(table.column(withIdentifier: .init("year")), toColumn: 1)
        check(await wait { prefs.appearance.tableColumns.prefix(2) == [.title, .year] }, "a moved column keeps its place: \(prefs.appearance.tableColumns.map(\.rawValue))")
        prefs.appearance.setShown(.genre, false)
        check(await wait { !shown().contains("genre") && shown()[1] == "year" }, "Genre hides: \(shown())")

        prefs.appearance.listDensity = .compact
        check(await wait { table.rowHeight == 20 }, "compact table rows: \(table.rowHeight)")
        check(rowHeight(subtitle: true) == 44 && rowHeight(subtitle: false) == 32, "compact song list rows: \(rowHeight(subtitle: true)), \(rowHeight(subtitle: false))")
        prefs.appearance.listDensity = .comfortable
        check(rowHeight(subtitle: true) == 54 && rowHeight(subtitle: false) == 42, "comfortable song list rows")

        prefs.appearance.accent = .purple
        let title = { table.view(atColumn: table.column(withIdentifier: .init("title")), row: 0, makeIfNecessary: false) as? SongsTable.TextCell }
        check(await wait { title().map { same($0.tint, prefs.appearance.accent.rgb) } == true }, "the table takes the purple accent")
        check(same(NSColor(Color.musicAccent), AppearanceSettings.Accent.purple.rgb), "Color.musicAccent is purple")

        prefs.appearance.accent = .album
        let cover = await Shot.first { model.player.artwork }
        check(cover != nil && CoverAccent.shared.image === cover, "the cover accent follows the player's cover")
        let expected = cover.flatMap(coverSamples).flatMap(AppearanceSettings.Accent.vivid) ?? AppearanceSettings.Accent.red.rgb
        check(same(NSColor(Color.musicAccent), expected), "Album Color is the cover's color: \(expected)")
        check(await wait { title().map { same($0.tint, expected) } == true }, "the table takes the album color")

        let widths = AppearanceSettings.GridDensity.allCases.map { density in
            prefs.appearance.density = density
            return albumGridColumns.first.map { if case .adaptive(let min, _) = $0.size { min } else { 0 } } ?? 0
        }
        check(widths == [120, 160, 230], "grid card widths follow the cover size: \(widths)")
    }

    /// Height of a song list row as SwiftUI lays it out.
    private static func rowHeight(subtitle: Bool) -> CGFloat {
        let row = TrackRow(title: "Song", subtitle: subtitle ? "Artist" : nil, time: 200) { TrackNumber(text: "1") } menu: { EmptyView() }
        return NSHostingView(rootView: row.frame(width: 600)).fittingSize.height
    }

    private static func same(_ color: NSColor, _ rgb: AppearanceSettings.Accent.RGB) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return false }
        return abs(c.redComponent - rgb.red) < 0.02 && abs(c.greenComponent - rgb.green) < 0.02 && abs(c.blueComponent - rgb.blue) < 0.02
    }
}
