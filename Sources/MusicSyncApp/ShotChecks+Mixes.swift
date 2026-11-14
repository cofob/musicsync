import Foundation
import Recommend
import Subsonic

/// `check:mixes`: mixes made from a seeded history keep the rules: early skips and "Not for Me" songs are left out,
/// no artist or album fills a mix, Top Picks follow the time of day and the shelves explain themselves.
/// Needs `scripts/big-server.py` (`MUSICSYNC_DEMO_SERVER`) and a fresh `MUSICSYNC_DEMO_DIR`: it replaces the history.
extension ShotChecks {
    static func mixRules(_ model: AppModel) async {
        guard model.config?.baseURL.host == "127.0.0.1" else { return check(false, "mixes needs MUSICSYNC_DEMO_SERVER on 127.0.0.1") }
        await Shot.mirrored(model)
        guard model.usesLocalLibrary, let library = model.library else { return check(false, "the local library") }
        let history = library.history
        try? await history.clear()
        var albums: [[Song]] = []
        for album in await library.database.albums(sort: .name, limit: 14) { albums.append(await library.database.album(id: album.id)?.song ?? []) }
        guard albums.count == 14, albums.allSatisfy({ $0.count >= 4 }) else { return check(false, "14 albums to play") }

        // Each day of the last month: albums 0–9 in turn at this hour, 10–12 twelve hours away, and the first two
        // songs of album 13 skipped after 8 seconds.
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        func record(_ songs: some Sequence<Song>, at start: Date, skip: Bool = false) async {
            for (i, song) in songs.enumerated() {
                let length = Double(song.duration ?? 200)
                try? await history.record(PlayEvent(songId: song.id, startedAt: start.addingTimeInterval(Double(i) * 90),
                                                    played: skip ? 8 : length, duration: length, source: .album))
            }
        }
        for day in 1...30 {
            let start = hour.addingTimeInterval(-Double(day) * 86400)
            await record(albums[day % 10], at: start)
            await record(albums[13].prefix(2), at: start.addingTimeInterval(1800), skip: true)
            await record(albums[10 + day % 3], at: start.addingTimeInterval(-12 * 3600))
        }
        let disliked = albums[0][1]
        await model.mixes.load(refresh: true)
        model.mixes.toggleDislike(disliked)
        check(await wait { model.mixes.mixes.allSatisfy { !$0.trackIds.contains(disliked.id) } }, "Not for Me takes the song out")
        await model.mixes.load(refresh: true)

        let mixes = model.mixes.mixes + model.mixes.because
        check(mixes.count >= 5 && model.mixes.because.count == 3, "mixes made: \(mixes.map(\.id))")
        let left = Set(albums[13].prefix(2).map(\.id) + [disliked.id])
        check(mixes.allSatisfy { Set($0.trackIds).isDisjoint(with: left) }, "no skipped or Not for Me song in a mix")
        for mix in mixes {
            let songs = model.mixes.songs(of: mix), size = mix.kind == .because ? 15 : 50
            let artists = Dictionary(grouping: songs) { $0.artistId ?? "" }.values.map(\.count).max() ?? 0
            let perAlbum = Dictionary(grouping: songs) { $0.albumId ?? "" }.values.map(\.count).max() ?? 0
            check(artists <= max(3, size / 5) && perAlbum <= max(2, size / 10), "\(mix.id): at most \(artists) songs per artist, \(perAlbum) per album")
        }
        check(model.mixes.because.allSatisfy { !$0.reason.isEmpty }, "because shelves explain: \(model.mixes.because.map(\.reason))")

        let now = Set(albums[0..<10].compactMap { $0.first?.albumId }), away = Set(albums[10..<13].compactMap { $0.first?.albumId })
        let picks = Set(model.mixes.topPicks)
        check(now.isSubset(of: picks) && picks.isDisjoint(with: away), "Top Picks hold the albums of this hour: \(picks.count)")
        let played = now.union(away)
        check(!model.mixes.discover.isEmpty && Set(model.mixes.discover).isDisjoint(with: played), "Discover: \(model.mixes.discover.count) unplayed albums")
        await model.loadHome()
        let shelf = model.shelves.first { $0.id == "picks" }
        check(shelf?.title == "Often Played \(model.mixes.dayPart.phrase)", "Home shows \(shelf?.title ?? "no Top Picks")")
        model.selection = .home
    }
}
