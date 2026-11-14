import Foundation

extension SidebarItem {
    /// Rows Settings > Appearance can hide, in sidebar order.
    static let editable: [SidebarItem] = [.home, .recentlyAdded, .artists, .albums, .songs, .genres, .favorites, .downloaded, .radio, .playlists]

    /// Saved name of a page (start page, hidden rows); nil for pages that may be gone at the next launch.
    var key: String? {
        switch self {
        case .home: "home"
        case .recentlyAdded: "recentlyAdded"
        case .artists: "artists"
        case .albums: "albums"
        case .songs: "songs"
        case .genres: "genres"
        case .favorites: "favorites"
        case .downloaded: "downloaded"
        case .radio: "radio"
        case .playlists: "playlists"
        case .search, .playlist, .deviceOverview, .deviceAlbums, .deviceSongs, .devicePlaylists: nil
        }
    }

    init?(key: String) {
        guard let item = Self.editable.first(where: { $0.key == key }) else { return nil }
        self = item
    }

    /// False when Settings > Appearance hides the row.
    @MainActor var isShown: Bool { key.map(AppPreferences.shared.appearance.shows) ?? true }
}
