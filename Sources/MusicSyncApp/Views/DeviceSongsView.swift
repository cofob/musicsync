import AppKit
import Preferences
import SwiftUI

/// All tracks on the iPod, in the table of the library Songs page. Rows come in pages over the sorted tracks
/// (`PagedList`). Double-click plays from the clicked row.
struct DeviceSongsView: View {
    @Environment(AppModel.self) private var model
    @State private var sort = TrackTable<DeviceTrack>.Column.title
    @State private var descending = false
    @State private var rows: [DeviceTrack] = []
    @State private var list: PagedList<DeviceTrack>?

    var body: some View {
        GeometryReader { geometry in
            TrackTable(list: list, sort: $sort, descending: $descending, onPlay: play, bottomInset: geometry.safeAreaInsets.bottom,
                       scrollKey: "\(sort) \(descending) \(model.query)")
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay {
            if model.ipod.snapshot == nil || list == nil {
                ProgressView()
            } else if rows.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note")
            }
        }
        .navigationTitle("Songs")
        .task(id: [String(model.ipod.version), model.searchText, String(describing: sort), String(descending)]) {
            if list != nil { try? await Task.sleep(for: .milliseconds(150)) }  // typing
            guard !Task.isCancelled else { return }
            let query = model.query
            let all = model.ipod.snapshot?.tracks ?? []
            let matching = query.isEmpty ? all : all.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
                    || $0.album.localizedCaseInsensitiveContains(query)
            }
            let sorted = matching.sorted(using: DeviceTrack.comparator(sort, descending: descending))
            let found = await AppModel.slices(sorted)
            guard !Task.isCancelled else { return }
            rows = sorted
            list = found
        }
    }

    /// Queues the shown rows, starting at `index`.
    private func play(_ index: Int) {
        model.play(rows, startAt: index)
    }
}

extension DeviceTrack: TrackTableItem {
    typealias Column = AppearanceSettings.SongsTableColumn

    static var isDevice: Bool { true }
    static var columns: [Column] { [.title, .time, .artist, .album, .rating, .plays, .size, .track, .year] }
    static func sortable(_ column: Column) -> Bool { true }

    static func comparator(_ column: Column, descending: Bool) -> KeyPathComparator<DeviceTrack> {
        var comparator: KeyPathComparator<DeviceTrack> = switch column {
        case .time: KeyPathComparator(\.duration)
        case .artist: KeyPathComparator(\.artist, comparator: .localizedStandard)
        case .album: KeyPathComparator(\.album, comparator: .localizedStandard)
        case .rating: KeyPathComparator(\.rating)
        case .plays: KeyPathComparator(\.plays)
        case .size: KeyPathComparator(\.size)
        case .track: KeyPathComparator(\.trackNumber)
        case .year: KeyPathComparator(\.year)
        default: KeyPathComparator(\.title, comparator: .localizedStandard)
        }
        comparator.order = descending ? .reverse : .forward
        return comparator
    }

    func cellText(_ column: Column) -> String {
        switch column {
        case .title: title
        case .time: formatTime(duration)
        case .artist: artist
        case .album: album
        case .plays: String(plays)
        case .size: formatBytes(size)
        case .track: trackNumber > 0 ? String(trackNumber) : ""
        case .year: year > 0 ? String(year) : ""
        default: ""
        }
    }

    func shownRating(_ model: AppModel) -> Int? { rating }

    static func menu(_ tracks: [DeviceTrack], _ model: AppModel, play: @escaping () -> Void) -> NSMenu? {
        guard !tracks.isEmpty else { return nil }
        let items = Group {
            Button("Play", systemImage: "play.fill", action: play)
            Divider()
            DeleteFromIPodButton { model.sync.tracksToDelete = tracks }
        }
        return NSHostingMenu(rootView: items.environment(model))
    }
}
