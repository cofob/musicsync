import Library
import Subsonic

/// `check:smart`: against `scripts/big-server.py` or `scripts/navidrome-dev.sh` in a fresh demo folder. Smart playlists
/// of several rules give the songs a plain filter over every mirrored song gives; limits hold; the page, the editor
/// preview and a download pin show the same songs.
extension ShotChecks {
    static func smart(_ model: AppModel) async {
        guard model.config?.baseURL.host == "127.0.0.1" else { return check(false, "smart needs MUSICSYNC_DEMO_SERVER on 127.0.0.1") }
        await Shot.mirrored(model)
        guard let db = model.library?.database, model.usesLocalLibrary else { return check(false, "local library ready") }
        let songs = await db.songs()
        check(songs.count >= 200, "mirror has the library (\(songs.count) songs)")
        typealias P = SmartPlaylist
        func fold(_ text: String?) -> String { (text ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
        func make(_ name: String, _ match: P.Match, _ items: [P.Item], limit: P.Limit = P.Limit()) -> P {
            var p = P(name: name)
            p.rules = P.Group(match: match, items: items)
            p.limit = limit
            return p
        }
        let smart = model.smartPlaylists
        let before = smart.playlists.count  // the demo defaults are shared: earlier runs may have left some
        let cases: [(P, (Song) -> Bool)] = [
            (make("Jazz 90s", .all, [.rule(P.Rule(field: .genre, op: .is, text: "jazz")),
                                     .rule(P.Rule(field: .year, op: .inRange, number: 1990, number2: 1999))]),
             { $0.genre == "Jazz" && (1990...1999).contains($0.year ?? 0) }),
            (make("Night or Echo", .any, [.rule(P.Rule(field: .title, op: .contains, text: "NIGHT")),
                                          .rule(P.Rule(field: .artist, op: .startsWith, text: "echo"))]),
             { fold($0.title).contains("night") || fold($0.artistName).hasPrefix("echo") }),
            (make("Long Favorites", .all, [.rule(P.Rule(field: .favorite, op: .isTrue)), .rule(P.Rule(field: .duration, op: .greater, number: 300))]),
             { $0.starred != nil && ($0.duration ?? 0) > 300 }),
            (make("Old Blues", .all, [.rule(P.Rule(field: .genre, op: .is, text: "Блюз")),
                                      .group(P.Group(match: .any, items: [.rule(P.Rule(field: .playCount, op: .greater, number: 8)),
                                                                          .rule(P.Rule(field: .year, op: .less, number: 1970))]))]),
             { $0.genre == "Блюз" && (($0.playCount ?? 0) > 8 || ($0.year ?? 0) < 1970) }),
        ]
        for (p, filter) in cases {
            await smart.save(p)
            let expected = Set(songs.filter(filter).map(\.id))
            let got = await smart.full(p.id)?.entry?.map(\.id) ?? []
            check(!expected.isEmpty && Set(got) == expected && got.count == expected.count, "\(p.name): \(got.count) of \(expected.count) songs match")
            check(await smart.preview(p)?.ids.count == expected.count, "\(p.name): the editor preview counts the same")
        }

        var top = P.Limit()
        top.isOn = true
        top.amount = 100
        top.by = .mostPlayed
        let most = make("Top 100", .all, [], limit: top)
        await smart.save(most)
        let picked = await smart.full(most.id)?.entry ?? []
        let pickedIDs = Set(picked.map(\.id))
        let lowest = picked.map { $0.playCount ?? 0 }.min() ?? 0
        let highestLeft = songs.filter { !pickedIDs.contains($0.id) }.map { $0.playCount ?? 0 }.max() ?? 0
        check(picked.count == 100 && lowest >= highestLeft, "Top 100: the most played songs (\(lowest) ≥ \(highestLeft) plays)")

        var hour = P.Limit()
        hour.isOn = true
        hour.amount = 60
        hour.unit = .minutes
        let random = make("Random Hour", .all, [], limit: hour)
        await smart.save(random)
        let length = (await smart.full(random.id)?.entry ?? []).reduce(0) { $0 + ($1.duration ?? 0) }
        check(length <= 3600 && length > 3600 - 420, "Random Hour: \(length) s")

        // The page and a download pin show the same songs as the rules.
        let first = cases[0].0
        await Shot.select(.playlist(first.id), model)
        check(await wait { smart.summaries[first.id]?.matches.ids.count == songs.filter(cases[0].1).count }, "the page shows the smart playlist")
        let expected = await smart.full(first.id)?.entry?.map(\.id)
        if let playlist = smart.playlist(first.id) { model.download(playlist) }
        check(await wait { model.downloads.order[.playlist(first.id)] == expected }, "a download pin keeps the smart playlist's songs")
        model.removeDownload(.playlist(first.id))
        check(await wait { !model.downloads.isPinned(.playlist(first.id)) }, "the pin goes again")
        check(smart.playlists.count == before + cases.count + 2, "the sidebar lists the \(cases.count + 2) new smart playlists")
        for p in cases.map(\.0) + [most, random] { smart.delete(p) }
        check(smart.playlists.count == before, "deleted smart playlists leave the sidebar")
    }
}
