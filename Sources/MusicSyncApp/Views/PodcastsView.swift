import SwiftUI
import Subsonic

/// Podcasts of the server: the newest episodes in a row, then a grid of the shows.
struct PodcastsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var deleting: PodcastChannel?

    var body: some View {
        let podcasts = model.podcasts
        let query = model.query
        let channels = query.isEmpty ? podcasts.channels : podcasts.channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Podcasts").font(.system(size: 30, weight: .bold))
                if query.isEmpty, !podcasts.newest.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ShelfHeader(title: "Newest Episodes")
                        SideShelf {
                            ForEach(podcasts.newest) { EpisodeCard(episode: $0, episodes: podcasts.newest) }
                        }
                    }
                }
                if !channels.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ShelfHeader(title: "Shows")
                        LazyVGrid(columns: albumGridColumns, spacing: 28) {
                            ForEach(channels) { channel in
                                ChannelCard(channel: channel, onDelete: podcasts.canEdit ? { deleting = channel } : nil)
                            }
                        }
                    }
                } else if !podcasts.isLoaded {
                    LazyVGrid(columns: albumGridColumns, spacing: 28) { ForEach(0..<8, id: \.self) { _ in PlaceholderCard() } }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .overlay {
            if let error = podcasts.error, !podcasts.isLoaded {
                LoadFailedView(message: error) { Task { await podcasts.load() } }
            } else if channels.isEmpty && podcasts.isLoaded {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("No Podcasts", systemImage: "mic")
                    } description: {
                        Text("Add a podcast with the address of its feed.")
                    } actions: {
                        if podcasts.canEdit { Button("Add Podcast") { adding = true }.buttonStyle(FilledCapsuleStyle()) }
                    }
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("Podcasts")
        .toolbar {
            if podcasts.canEdit {
                ToolbarItem { Button("Check for New Episodes", systemImage: "arrow.clockwise") { Task { await podcasts.refresh() } }.help("Check for New Episodes") }
                ToolbarItem { Button("Add Podcast", systemImage: "plus") { adding = true }.help("Add Podcast") }
            }
        }
        .task { await podcasts.load() }
        .sheet(isPresented: $adding) { AddPodcastSheet() }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let channel = deleting { Task { await podcasts.delete(channel) } } }
        } message: {
            Text("The podcast and its downloaded episodes are removed from the server for all users.")
        }
    }
}

/// Grid cell of a show; a click opens its episodes.
private struct ChannelCard: View {
    let channel: PodcastChannel
    let onDelete: (() -> Void)?

    var body: some View {
        NavigationLink(value: Route.podcast(channel)) {
            VStack(alignment: .leading, spacing: 2) {
                CoverImage(id: channel.coverArt, size: 400, cornerRadius: 10, symbol: "mic")
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2).padding(.bottom, 6)
                Text(channel.name).lineLimit(2)
                if channel.status == "error" {
                    Text(channel.errorMessage ?? "Update failed").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .contextMenu {
            if let onDelete { Button("Delete Podcast…", systemImage: "trash", action: onDelete) }
        }
    }
}

/// Wide card of a new episode: cover, date, title and length; a click plays it.
private struct EpisodeCard: View {
    @Environment(AppModel.self) private var model
    let episode: PodcastEpisode
    let episodes: [PodcastEpisode]

    var body: some View {
        Button { model.podcasts.play(episode, in: episodes) } label: {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(id: episode.coverArt, size: 200, cornerRadius: 8, symbol: "mic").frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episodeDate(episode)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(episode.name).font(.body.weight(.semibold)).lineLimit(2)
                        .foregroundStyle(model.player.current?.id == episode.song?.id ? Color.musicAccent : .primary)
                    Spacer(minLength: 0)
                    EpisodeProgress(episode: episode)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(width: 300, height: 100)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(CardPressStyle())
        .disabled(episode.song == nil)
        .contextMenu { EpisodeMenuItems(episode: episode, episodes: episodes) }
    }
}

/// Sheet to follow a podcast by its feed address.
struct AddPodcastSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Podcast").font(.title3.bold())
            Form { TextField("Feed URL", text: $url, prompt: Text(verbatim: "https://example.com/feed.xml")) }
                .formStyle(.grouped)
                .frame(height: 70)  // a grouped form scrolls and would otherwise take no height
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let feed = url.trimmingCharacters(in: .whitespaces)
                    Task { await model.podcasts.add(url: feed) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .tint(Color.musicAccent)
    }

    private var isValid: Bool {
        let scheme = URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
