import Charts
import Recommend
import SwiftUI
import Subsonic

/// "Your Stats": listening time, a chart of it and the top artists, albums and songs of a period.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("statsPeriod", store: .app) private var period = StatsPeriod.month
    @State private var input: BrowseModel.StatsInput?
    @State private var page: BrowseModel.StatsPage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("Your Stats").font(.system(size: 30, weight: .bold))
                    Spacer()
                    Picker("Period", selection: $period) {
                        ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(page?.stats.fromServer == true)
                }
                if let page {
                    if page.stats.isEmpty {
                        ContentUnavailableView("No Listening Yet", systemImage: "chart.bar",
                                               description: Text("Songs you play show up here.")).padding(.top, 60)
                    } else {
                        content(page)
                    }
                } else {
                    skeleton
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .navigationTitle("Your Stats")
        .task(id: model.libraryVersion) { input = await model.browse.statsInput() }
        .task(id: [period.rawValue, input == nil ? "" : "loaded"]) {
            guard let input else { return }
            let found = await model.browse.statsPage(input, period: period)
            if !Task.isCancelled { page = found }
        }
    }

    @ViewBuilder private func content(_ page: BrowseModel.StatsPage) -> some View {
        let stats = page.stats
        if stats.fromServer {
            Label("Based on the play counts of the server. Songs you play in MusicSync are counted here from now on.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        HStack(spacing: 16) {
            StatTile(title: "Listening Time", value: formatTotal(Int(stats.seconds)))
            StatTile(title: "Plays", value: stats.plays.formatted())
            StatTile(title: "Top Artist", value: stats.artists.first?.key ?? "—")
        }
        if !stats.bars.isEmpty { ListeningChart(bars: stats.bars, unit: period.bar) }
        if !page.artists.isEmpty {
            let plays = Dictionary(stats.artists.map { ($0.key, $0.plays) }) { a, _ in a }
            ArtistShelf(title: "Top Artists", artists: page.artists) { plays[$0.name].map(Self.plays) }
        }
        if !page.albums.isEmpty { AlbumShelf(title: "Top Albums", albums: page.albums) }
        if !page.songs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: "Top Songs")
                SongList(songs: page.songs, leading: .cover) { model.player.play(page.songs, startAt: $0) }.padding(.horizontal, -10)
            }
        }
    }

    private static func plays(_ count: Int) -> String { "\(count) \(count == 1 ? "play" : "plays")" }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 16) { ForEach(0..<3, id: \.self) { _ in PlaceholderBlock(height: 84, cornerRadius: 12) } }
            PlaceholderBlock(height: 200, cornerRadius: 12)
            PlaceholderRows(count: 6, cover: true)
        }
        .shimmering()
    }
}

/// Big number with a caption on a light gray card.
private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Minutes listened per day, week or month.
private struct ListeningChart: View {
    let bars: [ListeningStats.Bar]
    let unit: Calendar.Component

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Minutes Listened")
            Chart(bars) { bar in
                BarMark(x: .value("Date", bar.start, unit: unit), y: .value("Minutes", bar.seconds / 60))
                    .foregroundStyle(Color.musicAccent)
                    .cornerRadius(3)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
