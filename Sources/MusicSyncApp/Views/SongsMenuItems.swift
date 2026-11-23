import SwiftUI
import Subsonic

/// Actions on several selected songs, for context menus of song lists.
struct SongsMenuItems: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]

    var body: some View {
        Button("Play", systemImage: "play.fill") { model.player.play(songs) }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(songs) }
        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue(songs) }
        AddToPlaylistMenu(songs: songs)
        Divider()
        let starred = songs.allSatisfy(model.isStarred)
        Button(starred ? "Undo Favorite" : "Favorite", systemImage: starred ? "star.slash" : "star") { model.toggleStar(songs) }
        if model.downloads.manager != nil {
            let entries = songs.map { model.downloads.entries[$0.id] }
            if entries.contains(where: { $0?.isUserKept != true }) {
                Button("Download", systemImage: "arrow.down.circle") { model.download(songs) }
            }
            if entries.contains(where: { $0?.reasons.contains(.song) == true }) {
                Button("Remove Download", systemImage: "trash") { model.removeDownload(songs) }
            }
        }
        Divider()
        SongFileMenus(songs: songs)
    }
}

/// "Save to Folder" and "Share File", each with the original and the converted versions.
struct SongFileMenus: View {
    @Environment(AppModel.self) private var model
    let songs: [Song]

    var body: some View {
        Menu("Save to Folder", systemImage: "folder") {
            ForEach(SongFileVersion.allCases, id: \.self) { version in
                Button(version.title) { model.saveToFolder(songs, version) }
            }
        }
        Menu("Share File", systemImage: "square.and.arrow.up.on.square") {
            ForEach(SongFileVersion.allCases, id: \.self) { version in
                ShareLink(items: songs.map { SharedSongFile(song: $0, version: version, model: model) },
                          preview: { SharePreview($0.song.title, image: Image(systemName: "music.note")) }) { Text(version.title) }
            }
        }
    }
}
