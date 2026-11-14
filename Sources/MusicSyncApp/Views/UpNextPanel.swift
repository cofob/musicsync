import Playback
import SwiftUI
import Subsonic

/// Now Playing queue panel, as Apple Music's Up Next: History above (scroll up), the current song, then Playing Next
/// (added by the user), Continue Playing (the album or playlist) and AutoPlay. Drag to reorder within a section,
/// swipe, ⌫ or the context menu to remove, double-click to play.
struct UpNextPanel: View {
    @Environment(AppModel.self) private var model
    /// Key of the selected entry; ⌫ removes it.
    @State private var selected: Int?
    /// `player.history` one run loop turn late: History rows that change in the same update as the rows
    /// below them make AppKit warn of a reentrant table operation.
    @State private var history: [PlayItem] = []

    var body: some View {
        let player = model.player
        let line = player.line
        let user = line.upcoming(.user), source = line.upcoming(.source), auto = line.upcoming(.autoPlay)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                QueueToggle(title: "Shuffle", symbol: "shuffle", isOn: player.shuffle) { player.setShuffle(!player.shuffle) }
                if model.mixes.isAvailable {
                    QueueToggle(title: "AutoPlay", symbol: "infinity", isOn: model.mixes.autoPlay,
                                help: model.mixes.autoPlay ? "AutoPlay: similar songs play when the queue ends" : "Turn On AutoPlay") {
                        model.mixes.autoPlay.toggle()
                    }
                }
                if player.isMixing { AutoMixBadge() }
            }
            .padding(.horizontal, 10)  // in line with the rows
            ScrollViewReader { proxy in
                List {
                    if !history.isEmpty {
                        header("History")
                        ForEach(Array(history.enumerated()), id: \.offset) { _, item in
                            QueueRow(item: item) { historyMenu(item) }.opacity(0.6)
                                .onTapGesture(count: 2) { player.playAgain(item) }
                                .contextMenu { historyMenu(item) }
                        }
                    }
                    if let current = player.current {
                        header("Now Playing").id("now")
                        QueueRow(item: current, playing: true) { EmptyView() }
                    }
                    if !user.isEmpty { section("Playing Next", user, clear: true) }
                    if !source.isEmpty { section("Continue Playing", source, from: album(of: source), clear: user.isEmpty) }
                    if !auto.isEmpty { section("AutoPlay", auto, clear: false) }
                    if user.isEmpty && source.isEmpty && auto.isEmpty {
                        Text("Nothing up next").foregroundStyle(.secondary).listRowBackground(Color.clear)
                    }
                }
                .onChange(of: player.history.map(\.id), initial: true) { Task { history = player.history } }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .focusable().focusEffectDisabled()
                .onDeleteCommand { removeSelected() }
                .task {
                    // History sits above: scroll up to see it, as in Apple Music. The list lays out first.
                    try? await Task.sleep(for: .milliseconds(500))
                    proxy.scrollTo("now", anchor: .top)
                }
                .onChange(of: player.current?.id) { proxy.scrollTo("now", anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ slots: [PlayQueue<PlayItem>.Slot], from: String? = nil, clear: Bool) -> some View {
        let player = model.player
        header(title, from: from, clear: clear)
        // The item goes with its slot: a row may draw once more after the queue got shorter. An `if` in the row
        // instead makes the list resolve every row of a long queue to count its views, and Up Next opens late.
        ForEach(slots.filter { player.queue.indices.contains($0.index) }.map { ($0, player.queue[$0.index]) }, id: \.0.id) { slot, item in
            QueueRow(item: item, selected: selected == slot.id) { menu(slot, item) }
                .onTapGesture(count: 2) { player.play(at: slot.index) }
                .onTapGesture { selected = slot.id }
                .contextMenu { menu(slot, item) }
                .swipeActions { Button("Remove", systemImage: "minus.circle", role: .destructive) { player.remove(at: [slot.index]) } }
        }
        .onMove { offsets, destination in
            let target = destination < slots.count ? slots[destination].index : slots[slots.count - 1].index + 1
            player.move(from: IndexSet(offsets.map { slots[$0].index }), to: target)
        }
        .onDelete { player.remove(at: IndexSet($0.map { slots[$0].index })) }
    }

    /// Section title as a plain row: pinned headers would cover the rows under them on the clear background.
    private func header(_ title: String, from: String? = nil, clear: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                if let from { Text("From \(from)").foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if clear {
                Button("Clear") { model.player.clearUpcoming() }
                    .buttonStyle(HitAreaButtonStyle()).font(.body).foregroundStyle(Color.musicAccent)
            }
        }
        .padding(.top, 10).padding(.horizontal, 6)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .moveDisabled(true)
    }

    @ViewBuilder
    private func menu(_ slot: PlayQueue<PlayItem>.Slot, _ item: PlayItem) -> some View {
        let player = model.player
        Button("Play", systemImage: "play.fill") { player.play(at: slot.index) }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.remove(at: [slot.index])
            player.playNext([item])
        }
        Button("Remove from Queue", systemImage: "minus.circle") { player.remove(at: [slot.index]) }
        goTo(item)
    }

    @ViewBuilder
    private func historyMenu(_ item: PlayItem) -> some View {
        Button("Play", systemImage: "play.fill") { model.player.playAgain(item) }
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.player.playNext([item]) }
        goTo(item)
    }

    @ViewBuilder
    private func goTo(_ item: PlayItem) -> some View {
        if case .server(let song) = item {
            Divider()
            Button("Go to Album", systemImage: "square.stack") { model.showNowPlaying = false; model.goToAlbum(song) }
                .disabled(song.albumId == nil)
            Button("Go to Artist", systemImage: "music.microphone") { model.showNowPlaying = false; model.goToArtist(song) }
                .disabled(song.artistId == nil)
        }
    }

    private func removeSelected() {
        guard let selected, let i = model.player.line.keys.firstIndex(of: selected) else { return }
        model.player.remove(at: [i])
        self.selected = nil
    }

    /// The album every song of `slots` comes from, for "From <album>"; nil when they mix albums.
    private func album(of slots: [PlayQueue<PlayItem>.Slot]) -> String? {
        let queue = model.player.queue
        let albums = Set(slots.map { queue.indices.contains($0.index) ? queue[$0.index].album : nil })
        return albums.count == 1 ? albums.first ?? nil : nil
    }
}

/// Red capsule switch above the queue, as Apple Music's Shuffle and AutoPlay.
private struct QueueToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.bold))
                .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(isOn ? AnyShapeStyle(Color.musicAccent) : AnyShapeStyle(.primary.opacity(0.12)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(CardPressStyle())
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// One queue song: cover, title and "Artist — Album"; the time turns into a "•••" menu under the pointer.
private struct QueueRow<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let item: PlayItem
    var playing = false
    var selected = false
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(id: item.coverArt, size: 100, cornerRadius: 5).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).fontWeight(playing ? .semibold : .regular)
                Text([item.artist, item.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if playing {
                Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.secondary)
            } else if hovering {
                Menu { actions() } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                    .tint(.primary).help("More")
            } else {
                Text(item.duration.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.primary.opacity(0.15))
    }
}
