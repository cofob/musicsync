import SwiftUI
import Subsonic

/// A show: cover, description and its episodes, newest first.
struct PodcastChannelView: View {
    @Environment(AppModel.self) private var model
    let channel: PodcastChannel
    @State private var full: PodcastChannel?
    @State private var loadError: String?

    var body: some View {
        let episodes = (full?.episodes ?? []).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let latest = episodes.first { $0.song != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(latest: latest, episodes: episodes)
                if let loadError {
                    LoadFailedView(message: loadError) { Task { await load() } }
                } else if full == nil {
                    PlaceholderRows(count: 6).padding(.horizontal, 22)
                } else if episodes.isEmpty {
                    Text("No Episodes").foregroundStyle(.secondary).padding(.horizontal, 32)
                } else {
                    Text("Episodes").font(.title2.bold()).padding(.horizontal, 32).padding(.bottom, 4)
                    LazyVStack(spacing: 0) {
                        ForEach(episodes) { episode in
                            EpisodeRow(episode: episode, episodes: episodes) { await reload() }
                                .overlay(alignment: .bottom) { if episode.id != episodes.last?.id { Divider() } }
                        }
                    }
                    .padding(.horizontal, 32).padding(.bottom, 24)
                }
            }
        }
        .navigationTitle(channel.name)
        .task(id: channel.id) {
            await load()
            // The server downloads episodes in the background; their state is read again until it is done.
            while !Task.isCancelled, full?.episodes.contains(where: { $0.status == "downloading" }) == true {
                try? await Task.sleep(for: .seconds(5))
                await reload()
            }
        }
    }

    private func header(latest: PodcastEpisode?, episodes: [PodcastEpisode]) -> some View {
        let shown = full ?? channel
        let art = CoverImage(id: shown.coverArt, size: 600, cornerRadius: 10, symbol: "mic").frame(width: 220, height: 220)
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        let info = VStack(alignment: .leading, spacing: 8) {
            Text(shown.name).font(.system(size: 30, weight: .bold)).lineLimit(3)
            if full != nil {
                Text(episodes.count == 1 ? "1 episode" : "\(episodes.count) episodes")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            if let text = shown.description.map(ArtistInfo.plain), !text.isEmpty { ExpandableText(text: text) }
            Button {
                if let latest { model.podcasts.play(latest, in: episodes) }
            } label: { Label("Latest Episode", systemImage: "play.fill") }
                .buttonStyle(FilledCapsuleStyle()).disabled(latest == nil).padding(.top, 6)
        }
        .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 30) { art; info }
            VStack(alignment: .leading, spacing: 24) { art; info }
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
    }

    private func load() async {
        loadError = nil
        do { full = try await model.podcasts.channel(channel.id) ?? channel } catch where !error.isCancellation {
            loadError = error.localizedDescription
        } catch {}
    }

    /// After an action: the new state, keeping the page when the request fails.
    private func reload() async {
        if let channel = try? await model.podcasts.channel(channel.id) { full = channel }
    }
}

/// Episode: date, title, two lines of its description, then play button, progress and state.
private struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let episode: PodcastEpisode
    let episodes: [PodcastEpisode]
    let changed: () async -> Void

    var body: some View {
        let isCurrent = model.player.current?.id == episode.song?.id
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episodeDate(episode)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(episode.name).font(.body.weight(.semibold)).lineLimit(2).foregroundStyle(isCurrent ? Color.musicAccent : .primary)
                if let text = episode.description.map(ArtistInfo.plain), !text.isEmpty {
                    Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 12) {
                    if episode.song != nil {
                        Button("Play", systemImage: isCurrent && model.player.isPlaying ? "speaker.wave.2.fill" : "play.fill") {
                            model.podcasts.play(episode, in: episodes)
                        }
                        .buttonStyle(CircleIconStyle(size: 26)).help("Play \(episode.name)")
                    } else if episode.status != "downloading" {
                        Button("Download to Server", systemImage: "arrow.down") { Task { await model.podcasts.download(episode); await changed() } }
                            .buttonStyle(CircleIconStyle(size: 26)).help("Download to Server")
                    }
                    EpisodeProgress(episode: episode)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 8)
            RowMenu { EpisodeMenuItems(episode: episode, episodes: episodes, changed: changed) }.padding(.top, 2)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.podcasts.play(episode, in: episodes) }
        .contextMenu { EpisodeMenuItems(episode: episode, episodes: episodes, changed: changed) }
    }
}

/// Length, or a bar and the time left when a bookmark holds a position; the server state when it has no file.
struct EpisodeProgress: View {
    @Environment(AppModel.self) private var model
    let episode: PodcastEpisode

    var body: some View {
        let podcasts = model.podcasts
        HStack(spacing: 8) {
            if let progress = podcasts.progress(episode) {
                // Drawn, not a ProgressView: that one turns gray in an inactive window.
                Capsule().fill(.quaternary).frame(width: 60, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color.musicAccent).frame(width: 60 * progress) }
                Text(left(progress)).monospacedDigit()
            } else if podcasts.isPlayed(episode) {
                Label("Played", systemImage: "checkmark").labelStyle(.titleAndIcon)
            } else if let duration = episode.duration, duration > 0 {
                Text(formatTotal(duration))
            }
            if let state { Text(state) }
        }
        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
    }

    private func left(_ progress: Double) -> String {
        "\(formatTotal(Int(Double(episode.duration ?? 0) * (1 - progress)))) left"
    }

    private var state: String? {
        guard episode.song == nil else { return nil }
        return switch episode.status {
        case "downloading": "Downloading to Server…"
        case "error": "Download Failed"
        case "skipped": "Skipped"
        default: "Not on Server"
        }
    }
}

/// Episode actions for menus.
struct EpisodeMenuItems: View {
    @Environment(AppModel.self) private var model
    let episode: PodcastEpisode
    let episodes: [PodcastEpisode]
    var changed: () async -> Void = {}

    var body: some View {
        let podcasts = model.podcasts
        if let song = episode.song {
            Button("Play", systemImage: "play.fill") { podcasts.play(episode, in: episodes) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext([song]) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.addToQueue([song]) }
            Divider()
            if !podcasts.isPlayed(episode) {
                Button("Mark as Played", systemImage: "checkmark.circle") { podcasts.markPlayed(episode) }
            }
        } else if episode.status != "downloading" {
            Button("Download to Server", systemImage: "arrow.down.circle") { Task { await podcasts.download(episode); await changed() } }
        }
        if podcasts.canEdit, episode.song != nil {
            Divider()
            Button("Delete from Server", systemImage: "trash") { Task { await podcasts.deleteEpisode(episode); await changed() } }
        }
    }
}

/// "TODAY", "YESTERDAY", "1 NOV" or "1 NOV 2024", as in Apple Podcasts.
func episodeDate(_ episode: PodcastEpisode) -> String {
    guard let date = episode.date else { return "" }
    let calendar = Calendar.current
    let text = if calendar.isDateInToday(date) { "Today" } else if calendar.isDateInYesterday(date) { "Yesterday" }
        else if calendar.isDate(date, equalTo: .now, toGranularity: .year) { date.formatted(.dateTime.day().month(.abbreviated)) }
        else { date.formatted(.dateTime.day().month(.abbreviated).year()) }
    return text.uppercased()
}
