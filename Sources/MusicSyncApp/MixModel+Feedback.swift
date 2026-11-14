import Recommend
import Subsonic

/// "Not for Me" and the Home shelves that follow the listener's time and taste.
extension MixModel {
    /// Songs a mix, station or AutoPlay suggested; their menus offer "Not for Me".
    func isSuggested(_ id: String) -> Bool {
        songs[id] != nil || recorder.autoPlayed.contains(id) || station?.ids.contains(id) == true || dislikes.contains(id)
    }

    /// Marks a song "Not for Me" or takes the mark back, then makes the mixes of the day again without it.
    func toggleDislike(_ song: Song) {
        guard let history = app.library?.history else { return }
        let disliked = !dislikes.contains(song.id)
        if disliked { dislikes.insert(song.id) } else { dislikes.remove(song.id) }
        Task {
            do { try await history.setDisliked(song.id, disliked) } catch { return app.report(error) }
            loadedKey = nil
            await load()
        }
    }

    /// Home shelves with "Top Picks" for this part of the day and "Discover" from the listener's taste, when the
    /// history gives them; else the newest and random albums stay.
    func personalized(_ shelves: [AppModel.Shelf], albums: [Album]) -> [AppModel.Shelf] {
        guard isAvailable, !topPicks.isEmpty || !discover.isEmpty else { return shelves }
        let byId = Dictionary(albums.map { ($0.id, $0) }) { a, _ in a }
        var out = shelves
        let picks = topPicks.compactMap { byId[$0] }
        if !picks.isEmpty { out.insert(AppModel.Shelf(id: "picks", title: "Often Played \(dayPart.phrase)", albums: picks), at: 0) }
        let found = discover.compactMap { byId[$0] }
        if !found.isEmpty, let i = out.firstIndex(where: { $0.id == "random" }) { out[i] = AppModel.Shelf(id: "random", title: "Discover", albums: found) }
        return out
    }
}
