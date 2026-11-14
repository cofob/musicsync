import SwiftUI

/// Sidebar destinations. EXTENSION POINT: add device cases here, a matching row in `Sidebar`,
/// and a branch in `RootView.content(for:)`.
enum SidebarItem: Hashable {
    case search, home
    case recentlyAdded, artists, albums, songs, genres, favorites, downloaded, radio, podcasts
    case playlists, playlist(String)
    case deviceOverview, deviceAlbums, deviceSongs, devicePlaylists

    static let libraryItems: [SidebarItem] = [.recentlyAdded, .artists, .albums, .songs, .genres, .favorites, .downloaded]
    static let deviceItems: [SidebarItem] = [.deviceOverview, .deviceAlbums, .deviceSongs, .devicePlaylists]

    var isDevice: Bool { Self.deviceItems.contains(self) }

    var title: String {
        switch self {
        case .search: "Search"
        case .home: "Home"
        case .recentlyAdded: "Recently Added"
        case .albums, .deviceAlbums: "Albums"
        case .artists: "Artists"
        case .songs, .deviceSongs: "Songs"
        case .genres: "Genres"
        case .radio: "Radio"
        case .podcasts: "Podcasts"
        case .favorites: "Favorites"
        case .downloaded: "Downloaded"
        case .playlists: "All Playlists"
        case .devicePlaylists, .playlist: "Playlists"
        case .deviceOverview: "Overview"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .home: "house"
        case .recentlyAdded: "clock"
        case .albums, .deviceAlbums: "square.stack"
        case .artists: "music.microphone"
        case .songs, .deviceSongs: "music.note"
        case .genres: "guitars"
        case .radio: "dot.radiowaves.left.and.right"
        case .podcasts: "mic"
        case .favorites: "star"
        case .downloaded: "arrow.down.circle"
        case .playlists: "square.grid.3x3"
        case .devicePlaylists, .playlist: "music.note.list"
        case .deviceOverview: "ipod"
        }
    }

    /// Prompt of the toolbar search field: global search or "Find in …" for the page.
    var searchPrompt: String {
        switch self {
        case .search, .home: "Search"
        case .playlist: "Find in Playlist"
        case .playlists: "Find in Playlists"
        case .recentlyAdded: "Find in Albums"
        default: "Find in \(title)"
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        // No List selection: the system draws it blue (red icons on blue are unreadable); `pick` draws a gray one.
        List {
            ForEach([SidebarItem.search, .home].filter(\.isShown), id: \.self, content: row)
            Section("Library") {
                ForEach(SidebarItem.libraryItems.filter(\.isShown), id: \.self, content: row)
                if model.radio.isVisible, SidebarItem.radio.isShown { row(.radio) }
                if model.podcasts.isVisible, SidebarItem.podcasts.isShown { row(.podcasts) }
            }
            if model.ipod.current != nil || model.ipod.isOffline {
                Section {
                    ForEach(SidebarItem.deviceItems, id: \.self, content: row)
                    if model.ipod.current != nil { SyncStatusRow() }
                } header: { DeviceSectionHeader() }
            }
            Section {
                if SidebarItem.playlists.isShown { row(.playlists) }
                ForEach(model.playlists) { playlist in
                    PlaylistSidebarRow(playlist: playlist, isSelected: selection == .playlist(playlist.id))
                        .modifier(Pick(item: .playlist(playlist.id), selection: $selection))
                }
            } header: { PlaylistsHeader() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.client != nil { VStack(spacing: 6) { OfflineBanner(); SmartDownloadStatus(); LibraryStatusView() }.padding(.horizontal, 10).padding(.bottom, 8) }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        .task(id: model.client?.baseURL) { async let radio: Void = model.radio.load(); await model.podcasts.load(); await radio }
    }

    private func row(_ item: SidebarItem) -> some View {
        AccentLabel(title: item.title, symbol: item.symbol, isSelected: selection == item)
            .modifier(Pick(item: item, selection: $selection))
    }
}

/// Click selects the row; the selected row gets a neutral gray background, as in Apple Music.
private struct Pick: ViewModifier {
    let item: SidebarItem
    @Binding var selection: SidebarItem?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            // Grows into the row insets, so the whole gray shape takes clicks, not only the label.
            .contentShape(Rectangle().inset(by: -10))
            .onTapGesture { selection = item }
            .accessibilityAddTraits(selection == item ? [.isButton, .isSelected] : .isButton)
            .listRowBackground(RoundedRectangle(cornerRadius: 8)
                .fill(selection == item ? Color.primary.opacity(0.1) : .clear)
                .padding(.horizontal, 10))
    }
}

/// iPod name (a picker when several iPods are connected) and an eject button.
private struct DeviceSectionHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ipod = model.ipod
        HStack(spacing: 4) {
            if ipod.devices.count > 1 {
                Menu(name) {
                    ForEach(ipod.devices) { device in
                        Button(device.volumeName) { ipod.select(device) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            } else {
                Text(name)
            }
            Spacer()
            if ipod.isOffline {
                Text("Not Connected").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            } else {
                Button("Eject", systemImage: "eject.fill") { Task { await model.eject() } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(ipod.isEjecting || ipod.isSyncing)
                    // Sized like the header text and gray, as in the Finder sidebar.
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .help("Eject \(name)")
            }
        }
    }

    private var name: String { model.ipod.snapshot?.name ?? model.ipod.current?.volumeName ?? "iPod" }
}
