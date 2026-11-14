import SwiftUI

/// All tracks on the iPod; sortable columns. Double-click plays from the clicked row.
struct DeviceSongsView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\DeviceTrack.title, comparator: .localizedStandard)]
    @State private var rows: [DeviceTrack] = []
    @State private var selection = Set<DeviceTrack.ID>()

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title, comparator: .localizedStandard) { track in
                HStack {
                    Text(track.title).lineLimit(1)
                    Spacer(minLength: 4)
                    RowMenu(tint: selection.contains(track.id) ? .primary : .musicAccent) { Button("Play", systemImage: "play.fill") { play(track.id) } }
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Time", value: \.duration) { Text(formatTime($0.duration)).monospacedDigit() }
                .width(min: 50, ideal: 60, max: 80)
            TableColumn("Artist", value: \.artist, comparator: .localizedStandard) { Text($0.artist).lineLimit(1) }
            TableColumn("Album", value: \.album, comparator: .localizedStandard) { Text($0.album).lineLimit(1) }
            TableColumn("Rating", value: \.rating) { track in
                Text(String(repeating: "★", count: track.rating))
                    .foregroundStyle(selection.contains(track.id) ? Color.primary : .musicAccent)
            }
                .width(min: 50, ideal: 70, max: 90)
            TableColumn("Plays", value: \.plays) { Text(String($0.plays)).monospacedDigit() }
                .width(min: 40, ideal: 50, max: 70)
            TableColumn("Size", value: \.size) { Text(formatBytes($0.size)).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80, max: 100)
        }
        .contextMenu(forSelectionType: DeviceTrack.ID.self) { ids in
            if let id = ids.first { Button("Play", systemImage: "play.fill") { play(id) } }
            if !ids.isEmpty {
                Divider()
                DeleteFromIPodButton { model.sync.tracksToDelete = rows.filter { ids.contains($0.id) } }
            }
        } primaryAction: { ids in
            if let id = ids.first { play(id) }
        }
        .overlay {
            if model.ipod.snapshot == nil {
                ProgressView()
            } else if rows.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note")
            }
        }
        .navigationTitle("Songs")
        .onChange(of: model.ipod.version, initial: true) { rebuild() }
        .onChange(of: model.searchText) { rebuild() }
        .onChange(of: sortOrder) { rebuild() }
    }

    private func rebuild() {
        let query = model.query
        let all = model.ipod.snapshot?.tracks ?? []
        let matching = query.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
        rows = matching.sorted(using: sortOrder)
    }

    /// Queues the visible rows, starting at `id`.
    private func play(_ id: DeviceTrack.ID) {
        model.play(rows, startAt: rows.firstIndex { $0.id == id } ?? 0)
    }
}
