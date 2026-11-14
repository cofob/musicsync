import Foundation
import Library
import Observation
import Subsonic

/// Global search (Search page): suggestions while typing, results for a committed query.
/// Library scope reads the local database first and falls back to `search3`; iPod scope filters the device tracks.
@MainActor @Observable
final class SearchModel {
    enum Scope: Hashable { case library, ipod }

    enum Item: Identifiable, Hashable {
        case artist(Artist), album(Album), song(Song)
        case deviceAlbum(DeviceAlbum), deviceTrack(DeviceTrack)

        var id: String {
            switch self {
            case .artist(let a): "ar-\(a.id)"
            case .album(let a): "al-\(a.id)"
            case .song(let s): "so-\(s.id)"
            case .deviceAlbum(let a): "da-\(a.id)"
            case .deviceTrack(let t): "dt-\(t.id)"
            }
        }
    }

    /// Dropdown content: query completions, then the best items.
    struct Suggestions: Equatable {
        var completions: [String] = []
        var items: [Item] = []
        var count: Int { completions.count + items.count }
    }

    /// iPod results.
    struct DeviceResult: Equatable {
        var albums: [DeviceAlbum] = []
        var tracks: [DeviceTrack] = []
    }

    var scope = Scope.library
    /// Dropdown visibility; typing opens it, Escape / Return / a pick close it.
    var showsSuggestions = false
    /// Keyboard-selected dropdown row (completions first, then items).
    var highlighted: Int?
    private(set) var suggestions = Suggestions()
    /// Query shown on the results page.
    private(set) var query = ""
    private(set) var result: SearchResult3?
    private(set) var deviceResult = DeviceResult()
    private(set) var error: String?
    private(set) var isLoading = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var resultTask: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    /// Suggestions for `text`; call from `.task(id:)` so typing cancels the previous lookup.
    func suggest(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespaces)
        highlighted = nil
        guard !text.isEmpty, let app else { suggestions = Suggestions(); return }
        if scope == .ipod {
            let found = Self.deviceSearch(text, in: app.ipod.snapshot)
            suggestions = Suggestions(completions: [], items: found.albums.prefix(3).map(Item.deviceAlbum) + found.tracks.prefix(5).map(Item.deviceTrack))
            return
        }
        guard let found = await lookup(text, limit: 8, debounce: .milliseconds(250)), !Task.isCancelled else { return }
        suggestions = Suggestions(completions: Self.completions(text, found), items: Self.topItems(found, count: 7))
    }

    /// Shows results for `text` on the page.
    func commit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        showsSuggestions = false
        highlighted = nil
        query = text
        resultTask?.cancel()
        error = nil
        guard !text.isEmpty, let app else { result = nil; deviceResult = DeviceResult(); return }
        if scope == .ipod { deviceResult = Self.deviceSearch(text, in: app.ipod.snapshot); return }
        result = nil
        isLoading = true
        resultTask = Task {
            let found = await lookup(text, limit: 40, debounce: nil)
            guard !Task.isCancelled else { return }
            result = found
            isLoading = false
        }
    }

    func clear() {
        resultTask?.cancel()
        query = ""; result = nil; deviceResult = DeviceResult(); suggestions = Suggestions()
        error = nil; isLoading = false; showsSuggestions = false; highlighted = nil
    }

    /// Re-runs the shown query (scope changed, retry).
    func reload() { if !query.isEmpty { commit(query) } }

    /// Moves the keyboard highlight; wraps to nothing at both ends.
    func move(_ delta: Int) {
        guard suggestions.count > 0 else { return }
        let next = (highlighted ?? (delta > 0 ? -1 : suggestions.count)) + delta
        highlighted = suggestions.count > next && next >= 0 ? next : nil
    }

    /// Opens an artist or album, plays a song.
    func open(_ item: Item) {
        guard let app else { return }
        showsSuggestions = false
        switch item {
        case .artist(let a): app.show(.artist(a.id))
        case .album(let a): app.show(.album(a))
        case .song(let s): app.player.play([s])
        case .deviceAlbum(let a): app.show(.deviceAlbum(a.id))
        case .deviceTrack(let t): app.play([t])
        }
    }

    /// Return in the field: the highlighted row, else the typed text.
    func submit(_ text: String) {
        guard let row = highlighted else { return commit(text) }
        if row < suggestions.completions.count {
            let completion = suggestions.completions[row]
            app?.searchText = completion
            commit(completion)
        } else if suggestions.items.indices.contains(row - suggestions.completions.count) {
            open(suggestions.items[row - suggestions.completions.count])
        }
    }

    /// Local database when it has the library (instant), else `search3`. Nil on failure (shown in `error`).
    private func lookup(_ text: String, limit: Int, debounce: Duration?) async -> SearchResult3? {
        guard let app else { return nil }
        if app.usesLocalLibrary, let db = app.library?.database {
            let found = await db.search(text, limit: limit)
            let healthy = await db.isHealthy
            if healthy || !(found.artist.isEmpty && found.album.isEmpty && found.song.isEmpty) { return found }
        }
        if let debounce { try? await Task.sleep(for: debounce) }
        guard !Task.isCancelled, let client = app.client else { return nil }
        do {
            let found = try await client.search3(text, artistCount: min(limit, 20), albumCount: limit, songCount: limit)
            error = nil
            return found
        } catch where !error.isCancellation && !Task.isCancelled {
            if debounce == nil { self.error = error.localizedDescription; isLoading = false }
        } catch {}
        return nil
    }

    // MARK: Pure helpers

    /// Best matches first: the top artist, the top album, songs, then the other albums and artists.
    static func topItems(_ r: SearchResult3, count: Int) -> [Item] {
        let ordered = r.artist.prefix(1).map(Item.artist) + r.album.prefix(1).map(Item.album) + r.song.map(Item.song)
            + r.album.dropFirst().map(Item.album) + r.artist.dropFirst().map(Item.artist)
        return Array(ordered.prefix(count))
    }

    /// Up to three lowercase names from the result that start with (or contain) the typed text.
    static func completions(_ text: String, _ r: SearchResult3) -> [String] {
        let typed = fold(text)
        let names = r.artist.map(\.name) + r.album.map(\.name) + r.song.map(\.title)
            + r.song.compactMap { s in s.artistName.map { "\($0) \(s.title)" } }
        var seen = Set<String>(), prefix: [String] = [], inner: [String] = []
        for name in names {
            let lower = name.lowercased()
            guard seen.insert(fold(lower)).inserted else { continue }
            if fold(lower).hasPrefix(typed) { prefix.append(lower) } else if fold(lower).contains(typed) { inner.append(lower) }
        }
        return Array((prefix + inner).prefix(3))
    }

    /// Device albums and tracks where every word of `text` is in the title, artist or album.
    static func deviceSearch(_ text: String, in snapshot: DeviceSnapshot?) -> DeviceResult {
        let words = fold(text).split(separator: " ").map(String.init)
        guard let snapshot, !words.isEmpty else { return DeviceResult() }
        func matches(_ fields: String...) -> Bool {
            let haystack = fold(fields.joined(separator: " "))
            return words.allSatisfy(haystack.contains)
        }
        return DeviceResult(albums: snapshot.albums.filter { matches($0.name, $0.artist) },
                            tracks: snapshot.tracks.filter { matches($0.title, $0.artist, $0.album) }.prefix(200).map { $0 })
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
}
