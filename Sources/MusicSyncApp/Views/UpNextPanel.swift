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

    var body: some View {
        let player = model.player
        let line = player.line
        let user = line.upcoming(.user), source = line.upcoming(.source), auto = line.upcoming(.autoPlay)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up Next").font(.title2.bold())
                Spacer()
                if player.isMixing { AutoMixBadge() }
                Text(player.shuffle ? "Shuffle On" : "").font(.callout).foregroundStyle(.white.opacity(0.6))
                AutoPlayButton()
            }
            ScrollViewReader { proxy in
                List {
                    if !player.history.isEmpty {
                        header("History")
                        ForEach(Array(player.history.enumerated()), id: \.offset) { _, item in
                            row(item).opacity(0.6)
                                .onTapGesture(count: 2) { player.playAgain(item) }
                                .contextMenu { historyMenu(item) }
                        }
                    }
                    if let current = player.current {
                        header("Now Playing").id("now")
                        row(current, playing: true)
                    }
                    if !user.isEmpty { section("Playing Next", user, clear: true) }
                    if !source.isEmpty { section("Continue Playing", source, clear: user.isEmpty) }
                    if !auto.isEmpty { section("AutoPlay", auto, clear: false) }
                    if user.isEmpty && source.isEmpty && auto.isEmpty {
                        Text("Nothing up next").foregroundStyle(.white.opacity(0.6)).listRowBackground(Color.clear)
                    }
                }
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
        .padding(.trailing, 20).padding(.bottom, 50)
    }

    @ViewBuilder
    private func section(_ title: String, _ slots: [PlayQueue<PlayItem>.Slot], clear: Bool) -> some View {
        let player = model.player
        header(title, clear: clear)
        ForEach(slots) { slot in
            // A row may draw once more with its old slot after the queue got shorter.
            if player.queue.indices.contains(slot.index) {
                row(player.queue[slot.index], selected: selected == slot.id)
                    .onTapGesture(count: 2) { player.play(at: slot.index) }
                    .onTapGesture { selected = slot.id }
                    .contextMenu { menu(slot) }
                    .swipeActions { Button("Remove", systemImage: "minus.circle", role: .destructive) { player.remove(at: [slot.index]) } }
            }
        }
        .onMove { offsets, destination in
            let target = destination < slots.count ? slots[destination].index : slots[slots.count - 1].index + 1
            player.move(from: IndexSet(offsets.map { slots[$0].index }), to: target)
        }
        .onDelete { player.remove(at: IndexSet($0.map { slots[$0].index })) }
    }

    /// Section title as a plain row: pinned headers would cover the rows under them on the clear background.
    private func header(_ title: String, clear: Bool = false) -> some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.85))
            Spacer()
            if clear {
                Button("Clear") { model.player.clearUpcoming() }
                    .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.top, 10).padding(.horizontal, 6)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .moveDisabled(true)
    }

    @ViewBuilder
    private func menu(_ slot: PlayQueue<PlayItem>.Slot) -> some View {
        let player = model.player
        let item = player.queue[slot.index]
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

    private func row(_ item: PlayItem, playing: Bool = false, selected: Bool = false) -> some View {
        HStack(spacing: 12) {
            CoverImage(id: item.coverArt, size: 100, cornerRadius: 5).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).fontWeight(playing ? .semibold : .regular)
                Text(item.artist ?? "").font(.callout).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if playing {
                Image(systemName: model.player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.white.opacity(0.8))
            } else {
                Text(item.duration.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(selected ? Color.white.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.15))
    }
}
