import SwiftUI
import Subsonic

/// Internet radio stations of the server; admins may add, change and delete them.
struct RadioView: View {
    @Environment(AppModel.self) private var model
    /// The station in the editor; a new one has an empty id.
    @State private var editing: RadioStation?
    @State private var deleting: RadioStation?

    var body: some View {
        let radio = model.radio
        let stations = model.query.isEmpty ? radio.stations : radio.stations.filter { $0.name.localizedCaseInsensitiveContains(model.query) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Radio").font(.system(size: 30, weight: .bold))
                LazyVStack(spacing: 0) {
                    ForEach(stations) { station in
                        StationRow(station: station, onEdit: radio.canEdit ? { editing = station } : nil,
                                   onDelete: radio.canEdit ? { deleting = station } : nil)
                            .overlay(alignment: .bottom) { if station.id != stations.last?.id { Divider().padding(.leading, 74) } }
                    }
                }
                .padding(.horizontal, -10)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .overlay {
            if let error = radio.error, !radio.isLoaded {
                LoadFailedView(message: error) { Task { await radio.load() } }
            } else if stations.isEmpty && radio.isLoaded {
                if model.query.isEmpty {
                    ContentUnavailableView {
                        Label("No Radio Stations", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Add a station with the address of its stream.")
                    } actions: {
                        if radio.canEdit { Button("Add Station") { editing = Self.newStation }.buttonStyle(FilledCapsuleStyle()) }
                    }
                } else {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
        .navigationTitle("Radio")
        .toolbar {
            if radio.canEdit {
                ToolbarItem { Button("Add Station", systemImage: "plus") { editing = Self.newStation }.help("Add Station") }
            }
        }
        .sheet(item: $editing) { StationEditor(station: $0) }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let station = deleting { Task { await radio.delete(station) } } }
        } message: {
            Text("The station is removed from the server for all users.")
        }
    }

    private static let newStation = RadioStation(id: "", name: "", streamUrl: "")
}

/// Station symbol, name and address; double-click or the play button plays it.
private struct StationRow: View {
    @Environment(AppModel.self) private var model
    let station: RadioStation
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        let playing = model.player.current?.id == station.streamUrl
        HStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(Color.genre(station.name).gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name).font(.body.weight(.medium)).foregroundStyle(playing ? Color.musicAccent : .primary).lineLimit(1)
                Text(host).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Play", systemImage: playing ? "speaker.wave.2.fill" : "play.fill") { model.radio.play(station) }
                .buttonStyle(CircleIconStyle(size: 30)).help("Play \(station.name)")
            RowMenu { menu }
        }
        .padding(.horizontal, 10).frame(height: 66)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.radio.play(station) }
        .contextMenu { menu }
    }

    /// Host of the home page, else of the stream.
    private var host: String {
        (station.homePageUrl.flatMap(URL.init(string:))?.host() ?? URL(string: station.streamUrl)?.host()) ?? station.streamUrl
    }

    @ViewBuilder private var menu: some View {
        Button("Play", systemImage: "play.fill") { model.radio.play(station) }
        if let home = station.homePageUrl.flatMap(URL.init(string:)) {
            Link(destination: home) { Label("Open Home Page", systemImage: "safari") }
        }
        if let onEdit, let onDelete {
            Divider()
            Button("Edit…", systemImage: "pencil", action: onEdit)
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// Sheet to add a station (empty id) or change one.
struct StationEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let station: RadioStation
    @State private var name = ""
    @State private var stream = ""
    @State private var home = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(station.id.isEmpty ? "Add Station" : "Edit Station").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                TextField("Stream URL", text: $stream, prompt: Text("https://example.com/stream"))
                TextField("Home Page", text: $home, prompt: Text("Optional"))
            }
            .formStyle(.grouped)
            .frame(height: 170)  // a grouped form scrolls and would otherwise take no height
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let id = station.id.isEmpty ? nil : station.id
                    let page = home.trimmingCharacters(in: .whitespaces)
                    Task { await model.radio.save(id: id, name: name, streamUrl: stream, homePageUrl: page.isEmpty ? nil : page) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .tint(Color.musicAccent)
        .onAppear { name = station.name; stream = station.streamUrl; home = station.homePageUrl ?? "" }
    }

    private var isValid: Bool {
        let scheme = URL(string: stream)?.scheme?.lowercased()
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && (scheme == "http" || scheme == "https")
    }
}

/// Shown instead of the progress bar while a radio stream plays.
struct LiveLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.musicAccent).frame(width: 6, height: 6)
            Text("LIVE").font(.caption.weight(.bold)).tracking(1)
        }
        .frame(maxWidth: .infinity)
    }
}
