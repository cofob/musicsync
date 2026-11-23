import Library
import SwiftUI
import Subsonic

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var full: Playlist?
    @State private var loadError: String?

    var body: some View {
        // The list entry follows renames and edits made elsewhere; `playlist` may be an old copy from a route.
        let current = model.playlists.first { $0.id == playlist.id } ?? playlist
        let editable = model.canEdit(current)
        let entries = Array((full?.entry ?? []).enumerated())
        let rows = filter(entries)
        let songs = rows.map(\.element)
        ScrollView {
            header(current, editable: editable, songs: songs)
            if let loadError {
                LoadFailedView(message: loadError) { Task { await load() } }
            } else if full == nil {
                PlaceholderRows(count: playlist.songCount.map { min($0, 12) } ?? 10, cover: true).padding(.horizontal, 22)
            } else if songs.isEmpty && model.query.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note.list",
                                       description: Text(editable ? "Add songs with “Add to Playlist” or drag them onto the playlist in the sidebar." : ""))
            } else {
                VStack(spacing: 0) {
                    TrackListHeader()
                    // Moving needs the full list in playlist order.
                    let canMove = editable && rows.count == entries.count
                    SongList(songs: songs, leading: .cover, onPlay: { model.mixes.play(songs, from: .playlist, startAt: $0) },
                             onRemove: editable ? { (i: [Int]) in remove(at: i.map { rows[$0].offset }) } : nil,
                             onMove: canMove ? { (from: Int, to: Int) in move(from: from, to: to) } : nil)
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }
        }
        .navigationTitle(current.name)
        .task(id: [playlist.id, current.changed ?? ""]) { await load() }
    }

    private func header(_ current: Playlist, editable: Bool, songs: [Song]) -> some View {
        MediaHeader(cover: {
                        if SmartPlaylist.isSmart(current.id) { SmartPlaylistCover(playlist: current) } else {
                            CoverImage(id: current.coverArt, size: 600, cornerRadius: 10, symbol: "music.note.list")
                        }
                    },
                    title: current.name, canPlay: !songs.isEmpty,
                    onRename: editable ? { model.rename(current, to: $0, comment: current.comment) } : nil,
                    onPlay: { model.mixes.play(songs, from: .playlist, shuffled: false) },
                    onShuffle: { model.mixes.play(songs, from: .playlist, shuffled: true) }) {
            if let owner = current.owner { Text(owner).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.musicAccent) }
            if editable {
                InlineTextField(text: current.comment ?? "", prompt: "Add Description", font: .body, allowsEmpty: true) {
                    model.rename(current, to: current.name, comment: $0)
                }
                .foregroundStyle(.secondary)
            } else if let comment = current.comment, !comment.isEmpty {
                Text(comment).foregroundStyle(.secondary).lineLimit(3)
            }
            Text([current.songCount.map(formatSongs), current.duration.map(formatTotal)].compactMap { $0 }.joined(separator: ", "))
                .font(.callout).foregroundStyle(.secondary)
        } accessory: {
            DownloadButton(reason: .playlist(playlist.id)) { model.download(playlist) }
            SyncButton(isOn: model.sync.isPlaylistSelected(playlist.id)) { model.sync.togglePlaylist(playlist.id) }
            if editable { PlaylistHeaderMenu(playlist: current) }
            if SmartPlaylist.isSmart(current.id) { SmartPlaylistHeaderButtons(id: current.id) }
        }
    }

    private func load() async {
        loadError = nil
        do { full = try await model.playlist(playlist.id) } catch where !error.isCancellation {
            loadError = error.friendlyMessage
        } catch {}
    }

    /// "Find in Playlist". Rows keep their position in the playlist, which removal needs.
    private func filter(_ rows: [(offset: Int, element: Song)]) -> [(offset: Int, element: Song)] {
        let query = model.query
        guard !query.isEmpty else { return rows }
        return rows.filter { row in [row.element.title, row.element.artistName, row.element.album].contains { $0?.localizedCaseInsensitiveContains(query) == true } }
    }

    private func remove(at indexes: [Int]) {
        edit({ for i in indexes.sorted(by: >) { $0.remove(at: i) } }) { try await model.removeSongs(at: indexes, from: playlist) }
    }

    /// The dragged row takes the place of the row it is dropped on.
    private func move(from: Int, to: Int) {
        guard from != to, let entries = full?.entry, entries.indices.contains(from), entries.indices.contains(to) else { return }
        var ids = entries.map(\.id)
        ids.insert(ids.remove(at: from), at: to)
        edit({ $0.insert($0.remove(at: from), at: to) }) { try await model.reorder(playlist, songIds: ids) }
    }

    /// Shows the change at once; the server's playlist replaces it, or the old one comes back on failure.
    private func edit(_ change: (inout [Song]) -> Void, send: @escaping () async throws -> Playlist?) {
        guard let before = full else { return }
        var entries = before.entry ?? []
        change(&entries)
        full = before.withEntries(entries)
        Task {
            do { if let fresh = try await send() { full = fresh } } catch {
                full = before
                model.report(error)
            }
        }
    }
}

/// "•••" of an own playlist: rename, public, delete.
private struct PlaylistHeaderMenu: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist

    var body: some View {
        Menu {
            Toggle("Public", isOn: Binding(get: { playlist.isPublic == true }, set: { model.setPublic(playlist, $0) }))
            Divider()
            Button("Delete Playlist…", systemImage: "trash") { model.playlistPrompt = .delete(playlist) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.musicAccent)
                .frame(width: 32, height: 32).background(Color.primary.opacity(0.07), in: Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More")
    }
}

/// Text that turns into a field on click, for playlist titles. Return or leaving the field saves;
/// Escape keeps the old text. An empty name is refused unless `allowsEmpty`.
struct InlineTextField: View {
    let text: String
    let prompt: String
    let font: Font
    var allowsEmpty = false
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $draft, axis: .vertical)
            .textFieldStyle(.plain).font(font).lineLimit(1...3)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { if !focused { draft = text } }
            .onSubmit { focused = false }
            .onExitCommand { draft = text; focused = false }
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != text, allowsEmpty || !value.isEmpty else { draft = text; return }
        onCommit(value)
    }
}
