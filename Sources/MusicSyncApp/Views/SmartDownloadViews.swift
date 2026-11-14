import Library
import SwiftUI

extension SmartRule {
    /// Settings title.
    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .mixes: "Made for You Mixes"
        case .mostPlayed: "Heavy Rotation"
        case .recentAlbums: "Recently Added Albums"
        case .playlists: "Playlists"
        }
    }

    /// Why a song is downloaded, on its row.
    var badge: String {
        switch self {
        case .favorites: "Favorite"
        case .mixes: "Made for You"
        case .mostPlayed: "Heavy Rotation"
        case .recentAlbums: "Recently Added"
        case .playlists: "Playlist"
        }
    }
}

extension SmartConditions.Wait {
    var text: String {
        switch self {
        case .network: "Waiting for Wi-Fi or Ethernet"
        case .power: "Waiting for power"
        case .streaming: "Paused while music streams"
        }
    }
}

/// Sidebar status while smart downloads fetch songs.
struct SmartDownloadStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let smart = model.smartDownloads, count = smart.pending
        if count > 0, smart.wait == nil, !model.downloads.isOffline {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.dotted").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.musicAccent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Downloads").font(.callout).lineLimit(1)
                    Text("\(formatSongs(count)) for offline…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
                .glass(in: RoundedRectangle(cornerRadius: 10))
                .help("Smart downloads keep songs on this Mac. Settings > Downloads.")
        }
    }
}

/// Settings > Downloads > Smart Downloads.
struct SmartDownloadSettings: View {
    @Environment(AppModel.self) private var model
    private static let budgets: [Double] = [0.1, 0.5, 1, 2, 5, 10, 20, 50]

    var body: some View {
        @Bindable var downloads = model.downloads
        Section {
            rule(.favorites)
            rule(.mixes)
            rule(.mostPlayed) {
                Picker("Songs", selection: $downloads.settings.smart.mostPlayedCount) {
                    ForEach([25, 50, 100, 250, 500], id: \.self) { Text("Top \($0)").tag($0) }
                }
            }
            rule(.recentAlbums) {
                Picker("Added in", selection: $downloads.settings.smart.recentDays) {
                    ForEach([7, 14, 30, 90], id: \.self) { Text("Last \($0) days").tag($0) }
                }
            }
            rule(.playlists) { PlaylistPicker(ids: $downloads.settings.smart.playlistIDs) }
            budget("Total size", $downloads.settings.smart.budgetGB)
        } header: {
            Text("Smart Downloads")
        } footer: {
            Text("Keeps music offline on its own and updates it after each library sync. When a size is reached, the songs played least recently are left out. Your own downloads are never removed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Only on Wi-Fi or Ethernet", isOn: $downloads.settings.smart.unmeteredOnly)
            Toggle("Only when connected to power", isOn: $downloads.settings.smart.powerOnly)
            Toggle("Pause while music streams", isOn: $downloads.settings.smart.pauseWhileStreaming)
            LabeledContent("Status") {
                HStack {
                    Text(status).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                    Button("Update Now") { model.smartDownloads.run() }
                        .disabled(model.smartDownloads.isRunning || !downloads.settings.smart.isOn)
                }
            }
        }
    }

    private func rule(_ rule: SmartRule, @ViewBuilder options: () -> some View = { EmptyView() }) -> some View {
        @Bindable var downloads = model.downloads
        return Group {
            Toggle(rule.title, isOn: $downloads.settings.smart[rule].isOn)
            if downloads.settings.smart[rule].isOn {
                Group {
                    options()
                    budget("Up to", $downloads.settings.smart[rule].budgetGB)
                }
                .padding(.leading, 16)
            }
        }
    }

    private func budget(_ title: String, _ value: Binding<Double>) -> some View {
        Picker(title, selection: value) {
            ForEach(Self.budgets, id: \.self) { Text(formatBytes(Int64($0 * 1e9))).tag($0) }
        }
    }

    private var status: String {
        let smart = model.smartDownloads
        if smart.isRunning { return "Updating…" }
        if let wait = smart.wait, smart.pending > 0 { return "\(wait.text) · \(formatSongs(smart.pending)) to download" }
        if let problem = smart.problem { return problem }
        guard let run = smart.lastRun, let plan = smart.lastPlan else { return "Not updated yet" }
        let songs = Set(plan.songs.values.flatMap { $0.map(\.id) }).count
        let pending = smart.pending > 0 ? " · \(smart.pending) downloading" : ""
        return "Updated \(run.formatted(date: .omitted, time: .shortened)) · \(formatSongs(songs)), \(formatBytes(plan.bytes))\(pending)"
    }
}

/// Picks the playlists to keep in sync.
private struct PlaylistPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var ids: [String]

    var body: some View {
        LabeledContent("Keep in sync") {
            Menu(summary) {
                ForEach(model.playlists) { playlist in
                    Toggle(playlist.name, isOn: Binding(get: { ids.contains(playlist.id) }, set: { on in
                        if on { ids.append(playlist.id) } else { ids.removeAll { $0 == playlist.id } }
                    }))
                }
            }
            .fixedSize()
        }
    }

    private var summary: String {
        let names = model.playlists.filter { ids.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "None"
        case 1: return names[0]
        default: return "\(names.count) playlists"
        }
    }
}

/// Settings > Downloads > Cache.
struct PlaybackCacheSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var downloads = model.downloads
        Section {
            Picker("Cache size", selection: $downloads.settings.cacheGB) {
                Text("Off").tag(0.0)
                ForEach([0.5, 1, 2, 5, 10], id: \.self) { Text(formatBytes(Int64($0 * 1e9))).tag($0) }
            }
            LabeledContent("Used") {
                HStack {
                    Text("\(formatBytes(downloads.cache.usedBytes)) · \(formatSongs(downloads.cache.files.count))").foregroundStyle(.secondary)
                    Button("Clear Cache") { downloads.cache.clear() }.disabled(downloads.cache.files.isEmpty)
                }
            }
        } header: {
            Text("Cache")
        } footer: {
            Text("Songs you stream are kept here and play from this Mac next time, also offline. The oldest go when it is full. The cache does not count toward downloads.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
