import Library
import Subsonic
import SwiftUI

// MARK: Menus

/// "Download" / "Remove Download" for song menus. A song kept only by an album or playlist has no item:
/// it goes with them.
struct SongDownloadMenuItem: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        if model.downloads.manager != nil {
            let entry = model.downloads.entries[song.id]
            if entry?.reasons.contains(.song) == true {
                Button("Remove Download", systemImage: "trash") { model.removeDownload(song) }
            } else if entry?.isUserKept != true {
                Button("Download", systemImage: "arrow.down.circle") { model.download(song) }
            }
        }
    }
}

/// "Download" / "Remove Download" for album and playlist menus.
struct PinMenuItem: View {
    @Environment(AppModel.self) private var model
    let reason: DownloadReason
    let download: () -> Void

    var body: some View {
        if model.downloads.manager != nil {
            if model.downloads.isPinned(reason) {
                Button("Remove Download", systemImage: "trash") { model.removeDownload(reason) }
            } else {
                Button("Download", systemImage: "arrow.down.circle", action: download)
            }
        }
    }
}

// MARK: Page header

/// Download control of album and playlist pages: an arrow, a progress ring while
/// downloading, then "Downloaded". Removing asks first.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let reason: DownloadReason
    let download: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        if model.downloads.manager != nil {
            control
                .confirmationDialog("Remove the download?", isPresented: $confirmRemove) {
                    Button("Remove Download", role: .destructive) { model.removeDownload(reason) }
                } message: {
                    Text("The songs stay in your library and can be downloaded again.")
                }
        }
    }

    @ViewBuilder private var control: some View {
        switch model.downloads.state(of: reason) {
        case .none:
            icon("arrow.down.circle", action: download).help("Download")
        case .downloading(let fraction):
            Button { confirmRemove = true } label: { DownloadRing(fraction: fraction) }
                .buttonStyle(HitAreaButtonStyle(width: 34, height: 34))
                .help(blockedHelp ?? "Downloading \(Int(fraction * 100))% · Click to stop")
        case .failed(let count):
            icon("exclamationmark.circle") { Task { await model.downloads.manager?.retry(model.downloads.groups[reason]?.ids) } }
                .help("\(formatSongs(count)) failed to download · Click to retry")
        case .done:
            Button { confirmRemove = true } label: {
                Label("Downloaded", systemImage: "checkmark.circle.fill").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(HitAreaButtonStyle(height: 34)).padding(.leading, 4).help("Remove Download…")
        }
    }

    private func icon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 24, weight: .regular)).foregroundStyle(Color.musicAccent) }
            .buttonStyle(HitAreaButtonStyle(width: 34, height: 34))
    }

    private var blockedHelp: String? {
        switch model.downloads.status.blocked {
        case .storageLimit?: "Paused: the storage limit in Settings is reached"
        case .diskFull?: "Paused: the disk is full"
        case .offline?: "Paused: offline"
        case nil: nil
        }
    }
}

/// Accent progress ring with a stop square, for a running download.
struct DownloadRing: View {
    let fraction: Double
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(Color.musicAccent.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Color.musicAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
            RoundedRectangle(cornerRadius: 1).fill(Color.musicAccent).frame(width: size * 0.32, height: size * 0.32)
        }
        .frame(width: size, height: size)
    }
}

// MARK: Badges

/// Small "downloaded" mark on an album cover.
struct DownloadBadge: View {
    @Environment(AppModel.self) private var model
    let reason: DownloadReason

    var body: some View {
        if let (symbol, help) = info {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .help(help)
        }
    }

    private var info: (String, String)? {
        switch model.downloads.state(of: reason) {
        case .none: nil
        case .done: ("arrow.down", "Downloaded")
        case .downloading: ("arrow.down.circle.dotted", "Downloading")
        case .failed: ("exclamationmark", "Download failed")
        }
    }
}

/// "Offline" hint above the library status while the server cannot be reached.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.downloads.isOffline {
            Label("Offline", systemImage: "wifi.slash")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 30)
                .glass(in: RoundedRectangle(cornerRadius: 10))
                .help("The server cannot be reached. Downloaded music still plays.")
        }
    }
}

/// Album page header accessory: download control and the iPod sync toggle.
struct AlbumHeaderButtons: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        DownloadButton(reason: .album(album.id)) { model.download(album) }
        AlbumSyncButton(album: album)
    }
}
