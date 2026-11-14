import SwiftUI
import Subsonic

/// "Add to Playlist" submenu: "New Playlist…" first, then the playlists the user may change.
/// `songIds` is asked only when an item is chosen (an album fetches its songs then).
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let songIds: () async -> [String]

    var body: some View {
        Menu("Add to Playlist", systemImage: "text.badge.plus") {
            Button("New Playlist…", systemImage: "plus") { Task { model.playlistPrompt = .create(songIds: await songIds()) } }
            Divider()
            ForEach(model.editablePlaylists) { playlist in
                Button(playlist.name) { Task { model.add(await songIds(), to: playlist) } }
            }
        }
    }
}

extension AddToPlaylistMenu {
    init(songs: [Song]) { self.init { songs.map(\.id) } }
}

/// The sheet and alerts behind `AppModel.playlistPrompt`. Attached once, to the root view.
struct PlaylistDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let prompt = model.playlistPrompt
        content
            .sheet(isPresented: binding { if case .create = $0 { true } else { false } }) {
                if case .create(let ids)? = prompt { NewPlaylistSheet(songIds: ids) }
            }
            .confirmationDialog(deleteTitle(prompt), isPresented: binding { if case .delete = $0 { true } else { false } }) {
                if case .delete(let playlist)? = prompt {
                    Button("Delete", role: .destructive) { model.delete(playlist) }
                }
            } message: {
                Text("The playlist is deleted from the server. The songs stay in your library.")
            }
            .alert(duplicateTitle(prompt), isPresented: binding { if case .duplicates = $0 { true } else { false } }) {
                if case .duplicates(let ids, let playlist, _)? = prompt {
                    Button("Add Anyway") { Task { await model.append(ids, to: playlist) } }
                    Button("Skip") { Task { await skipDuplicates(ids, playlist) } }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                Text("You can add them again or skip them.")
            }
    }

    /// True while `prompt` matches; false clears it.
    private func binding(_ matches: @escaping (PlaylistPrompt) -> Bool) -> Binding<Bool> {
        Binding(get: { model.playlistPrompt.map(matches) ?? false }, set: { if !$0 { model.playlistPrompt = nil } })
    }

    private func deleteTitle(_ prompt: PlaylistPrompt?) -> String {
        if case .delete(let p)? = prompt { "Delete “\(p.name)”?" } else { "" }
    }

    private func duplicateTitle(_ prompt: PlaylistPrompt?) -> String {
        guard case .duplicates(let ids, let p, let count)? = prompt else { return "" }
        return count == 1 && ids.count == 1 ? "This song is already in “\(p.name)”."
            : "\(formatSongs(count)) already in “\(p.name)”."
    }

    private func skipDuplicates(_ ids: [String], _ playlist: Playlist) async {
        let present = Set((try? await model.playlist(playlist.id))?.entry?.map(\.id) ?? [])
        await model.append(ids.filter { !present.contains($0) }, to: playlist)
    }
}

/// Name and description of a new playlist. Return creates it.
struct NewPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let songIds: [String]
    @State private var name = "New Playlist"
    @State private var comment = ""
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "music.note.list").font(.system(size: 30)).foregroundStyle(.secondary)
                    .frame(width: 72, height: 72).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Playlist").font(.title3.bold())
                    Text(songIds.isEmpty ? "Empty playlist" : formatSongs(songIds.count)).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Name", text: $name).focused($nameFocused)
                TextField("Description", text: $comment, prompt: Text("Optional"), axis: .vertical).lineLimit(2...4)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        isCreating = true
        Task {
            await model.createPlaylist(name: trimmed, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines), songIds: songIds)
            dismiss()
        }
    }
}
