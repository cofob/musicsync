import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var sync = model.sync
        let selection = model.selection ?? .home
        ZStack {
            NavigationSplitView {
                // The List writes nil when a click clears its selection; ignoring it keeps the current page.
                Sidebar(selection: Binding(get: { model.selection }, set: { if let item = $0 { model.selection = item } }))
            } detail: {
                ZStack {
                    Group {
                        if model.client == nil && !selection.isDevice {
                            OnboardingView()
                        } else {
                            NavigationStack(path: $model.path) {
                                content(for: selection)
                                    .playerInset()
                                    .navigationDestination(for: Route.self) { destination(for: $0).playerInset() }
                            }
                            // Hiding the window toolbar for Now Playing can leave the root page drawn over
                            // a pushed one; a new stack (same path) shows only the top page.
                            .id(model.showNowPlaying && !model.path.isEmpty)
                            .softTopEdge()
                        }
                    }
                    // A new identity per page lets the old one fade out and the new one in.
                    .id(selection)
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.2), value: selection)
                .overlay(alignment: .top) { suggestions(selection) }
                .toolbar {
                    // macOS 26 wraps toolbar items in a glass capsule; the field draws its own, so hide that one.
                    if #available(macOS 26, *) {
                        ToolbarItem(placement: .principal) { ToolbarSearchField(prompt: prompt(selection)) }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .principal) { ToolbarSearchField(prompt: prompt(selection)) }
                    }
                    if selection == .search && model.ipod.current != nil {
                        ToolbarItem(placement: .primaryAction) { SearchScopePicker() }
                    }
                }
                // Only the detail sets a minimum: one on the whole split view, wider than the window
                // minus the opening sidebar, makes the sidebar animation overflow and snap back.
                .frame(minWidth: 680, minHeight: 560)
            }
            if model.showNowPlaying {
                NowPlayingView().transition(.move(edge: .bottom)).zIndex(1)
            }
        }
        .animation(.smooth(duration: 0.35), value: model.showNowPlaying)
        .toolbar(model.showNowPlaying ? .hidden : .automatic, for: .windowToolbar)
        .tint(Color.musicAccent)
        .task(id: model.searchText) {
            guard selection == .search else { return }
            let search = model.search
            if model.searchText.isEmpty { return search.clear() }
            search.showsSuggestions = model.searchFieldFocused && model.searchText != search.query
            await search.suggest(model.searchText)
        }
        .onChange(of: model.search.scope) {
            model.search.reload()
            if !model.searchText.isEmpty { Task { await model.search.suggest(model.searchText) } }
        }
        .onChange(of: model.ipod.current == nil && model.ipod.snapshot == nil) { _, gone in
            if gone, selection.isDevice { model.selection = .home }
        }
        .onChange(of: model.ipod.current?.id) {
            if model.ipod.current == nil, !model.sync.isRunning { model.sync.showSheet = false }
            if model.ipod.current == nil { model.search.scope = .library }
        }
        .onChange(of: model.selection) {
            AppPreferences.shared.remember(model.selection)
            model.path = []
            model.searchText = ""
            model.search.clear()
            if model.selection == .search, Shot.output == nil { model.searchFocusRequest += 1 }  // focus activates the app
        }
        .onChange(of: model.player.queue.isEmpty) { if model.player.queue.isEmpty { model.showNowPlaying = false } }
        .onChange(of: model.ipod.version) { model.sync.deviceUpdated() }
        .sheet(item: $model.infoSong) { SongInfoView(song: $0) }
        .modifier(PlaylistDialogs())
        .sheet(isPresented: $model.showGuide) { GuideView() }
        .task { if !model.demo, !UserDefaults.app.bool(forKey: GuideView.shownKey) { model.showGuide = true } }
        .sheet(isPresented: $sync.showSheet) { SyncSheet() }
        .alert("Already on This iPod", isPresented: Binding(get: { model.sync.foreignAlbum != nil },
                                                            set: { if !$0 { model.sync.foreignAlbum = nil } })) {
            Button("Select Anyway") { if let album = model.sync.foreignAlbum { model.sync.toggle(album, confirmed: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(model.sync.foreignAlbum?.name ?? "")” was put on the iPod by iTunes. MusicSync skips it while that copy is there, to avoid duplicates.")
        }
        .confirmationDialog("Delete \(formatSongs(model.sync.tracksToDelete.count)) from the iPod?",
                            isPresented: Binding(get: { !model.sync.tracksToDelete.isEmpty }, set: { if !$0 { model.sync.tracksToDelete = [] } })) {
            Button("Delete", role: .destructive) { model.sync.deleteConfirmed() }
        } message: {
            Text("The files are deleted from the iPod. This cannot be undone. Songs selected through an artist or playlist come back with the next sync.")
        }
        .confirmationDialog("Delete orphaned files?", isPresented: $sync.confirmCleanUp) {
            Button("Delete", role: .destructive) { model.sync.cleanOrphans() }
        } message: {
            let orphans = model.ipod.snapshot?.orphans
            Text("\(orphans?.count ?? 0) files (\(formatBytes(orphans?.bytes ?? 0))) on the iPod belong to no song. This cannot be undone.")
        }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func content(for item: SidebarItem) -> some View {
        switch item {
        case .search: SearchResultsView()
        case .home: HomeView()
        case .recentlyAdded: AlbumsView(recentlyAdded: true)
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .songs: SongsView()
        case .genres: GenresView()
        case .radio: RadioView()
        case .favorites: FavoritesView()
        case .downloaded: DownloadedView()
        case .playlists: PlaylistsView()
        case .playlist(let id):
            if let playlist = model.playlists.first(where: { $0.id == id }) {
                PlaylistDetailView(playlist: playlist).id(id)
            } else {
                ContentUnavailableView("Playlist Not Found", systemImage: "music.note.list")
            }
        case .deviceOverview: DeviceOverviewView()
        case .deviceAlbums: DeviceAlbumsView()
        case .deviceSongs: DeviceSongsView()
        case .devicePlaylists: DevicePlaylistsView()
        }
    }

    /// EXTENSION POINT: pass sync badges/toggles via the `AlbumDetailView` header accessory.
    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .album(let album): AlbumDetailView(album: album)
        case .artist(let id): ArtistDetailView(id: id)
        case .playlist(let playlist): PlaylistDetailView(playlist: playlist)
        case .deviceAlbum(let id): DeviceAlbumDetailView(id: id)
        case .devicePlaylist(let id): DevicePlaylistDetailView(id: id)
        case .genre(let name): GenreDetailView(genre: name)
        case .mix(let id): MixDetailView(id: id)
        case .stats: StatsView()
        }
    }

    private func prompt(_ selection: SidebarItem) -> String {
        guard selection == .search else { return selection.searchPrompt }
        return model.search.scope == .ipod ? "Search iPod" : "Search Library"
    }

    /// Dropdown under the toolbar field while typing on the Search page; a click outside closes it.
    @ViewBuilder
    private func suggestions(_ selection: SidebarItem) -> some View {
        let search = model.search
        if selection == .search, search.showsSuggestions, !model.searchText.isEmpty, search.suggestions.count > 0 {
            ZStack(alignment: .top) {
                Color.clear.contentShape(Rectangle()).onTapGesture { search.showsSuggestions = false }
                SearchSuggestionsView().padding(.top, 6)
            }
        }
    }
}

struct OnboardingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect to Navidrome", systemImage: "server.rack")
        } description: {
            Text("Enter your server address and credentials in Settings.")
        } actions: {
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// Floating player capsule over the bottom of a page; scroll content passes under it.
    /// Applied per page because pushed pages do not inherit an inset set on the stack.
    func playerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) { ResumeBanner(); PlayerCapsule() }.padding(.horizontal, 20).padding(.bottom, 14)
        }
    }
}
