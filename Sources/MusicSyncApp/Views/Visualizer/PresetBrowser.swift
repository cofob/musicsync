import MilkDropKit
import SwiftUI

/// All MilkDrop presets by category, as pictures on a demo track that load as they scroll into view. Hovering a
/// picture plays the preset live on the music; clicking shows it.
struct PresetBrowser: View {
    let milkDrop: MilkDrop
    let player: Player
    @State private var category = PresetBrowser.all
    @State private var search = ""
    @State var hovered: String?
    @State private var preview = PresetPreview(textureFolders: [MilkDrop.userFolder])

    static let all = "All Presets"
    static let store = ThumbnailStore(folder: MilkDrop.thumbnailFolder, index: MilkDrop.compileIndex, textureFolders: [MilkDrop.userFolder],
                                      measures: MilkDrop.measuresFile)

    var body: some View {
        let entries = milkDrop.entries
        let counts = Dictionary(grouping: entries, by: \.category).mapValues(\.count)
        HStack(spacing: 0) {
            List(selection: Binding(get: { category }, set: { category = $0 ?? Self.all })) {
                row(Self.all, count: entries.count)
                Section("Categories") {
                    ForEach(categories(counts), id: \.self) { row($0, count: counts[$0] ?? 0) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                TextField("Search presets", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                grid(shown(entries))
            }
        }
        .frame(width: 780, height: 520)
        .onAppear {
            preview.samples = MilkDropView.samples(player)
            preview.show(entries.first { $0.name == hovered })  // a hover set from outside (screenshots)
        }
        .onDisappear { preview.show(nil) }
    }

    private func row(_ name: String, count: Int) -> some View {
        LabeledContent { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() } label: { Text(name) }
            .tag(name)
    }

    /// Built-in and the user's own first, then the downloaded ones by name.
    private func categories(_ counts: [String: Int]) -> [String] {
        let fixed = [PresetLibrary.builtInCategory, PresetLibrary.ownCategory].filter { counts[$0] != nil }
        return fixed + counts.keys.filter { !fixed.contains($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func shown(_ entries: [PresetLibrary.Entry]) -> [PresetLibrary.Entry] {
        entries.filter { (category == Self.all || $0.category == category) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    private func grid(_ entries: [PresetLibrary.Entry]) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 14) {
                    ForEach(entries, id: \.name) { entry in
                        PresetCard(entry: entry, flashes: milkDrop.flashes, isCurrent: entry.name == milkDrop.current, isHovered: hovered == entry.name, preview: preview)
                            .id(entry.name)
                            .onHover { inside in
                                if inside { hovered = entry.name; preview.show(entry) }
                                else if hovered == entry.name { hovered = nil; preview.show(nil) }
                            }
                            .onTapGesture { milkDrop.select(entry.name) }
                    }
                }
                .padding(12)
            }
            .onAppear { if let current = milkDrop.current { scroll.scrollTo(current, anchor: .center) } }
            .overlay { if entries.isEmpty { ContentUnavailableView.search(text: search) } }
        }
    }
}

/// One preset: its picture (or, under the pointer, the preset live) and its name.
private struct PresetCard: View {
    let entry: PresetLibrary.Entry
    /// Whether a preset flashes too much, once measured (`MilkDropController.flashes`).
    let flashes: (PresetLibrary.Entry) -> Bool?
    let isCurrent: Bool
    let isHovered: Bool
    let preview: PresetPreview
    @State private var image: CGImage?
    @State private var loaded = false
    @State private var flashing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Color.black
                if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                else if loaded { Text("Does not compile").font(.caption2).foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
                if isHovered { MilkDropSurface(preview) }
            }
            .overlay(alignment: .topTrailing) {
                if flashing {
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.orange)
                        .padding(4).background(.black.opacity(0.6), in: Circle()).padding(5)
                        .help("Flashes too much for people sensitive to flashing lights")
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isCurrent ? Color.accentColor : .white.opacity(isHovered ? 0.4 : 0.1), lineWidth: isCurrent ? 2.5 : 1)
            }
            Text(entry.name).font(.caption).lineLimit(2, reservesSpace: true).foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        // Made or read when the card scrolls into view; dropped from the queue when it scrolls away first.
        .task(id: entry.url) {
            image = await PresetBrowser.store.thumbnail(entry)
            loaded = !Task.isCancelled
            flashing = flashes(entry) == true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(flashing ? "\(entry.name), flashes" : entry.name)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
