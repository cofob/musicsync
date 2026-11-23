import MilkDropKit
import SwiftUI

/// Downloads of the "Cream of the Crop" preset pack, by category, into `MilkDrop.downloadedFolder`.
@Observable @MainActor final class PresetPacks {
    private(set) var installed: [String: Int] = [:]
    /// Categories being downloaded and the download's progress (0…1).
    private(set) var loading: Set<String> = []
    private(set) var progress = 0.0
    private(set) var error: String?
    private var task: Task<Void, Never>?

    func refresh() { installed = PresetPack.installed(in: MilkDrop.downloadedFolder) }

    /// One download at a time: the archive holds all categories.
    func download(_ categories: Set<String>) {
        guard task == nil, !categories.isEmpty else { return }
        loading = categories
        progress = 0
        error = nil
        task = Task {
            do {
                _ = try await PresetPack.download(categories, to: MilkDrop.downloadedFolder) { value in
                    Task { @MainActor in self.progress = value }
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            loading = []
            task = nil
            changed()
        }
    }

    func cancel() { task?.cancel() }

    func remove(_ category: String) {
        try? PresetPack.remove(category, from: MilkDrop.downloadedFolder)
        changed()
    }

    private func changed() {
        refresh()
        NotificationCenter.default.post(name: VisualizerSettings.presetsChanged, object: nil)
    }
}

/// Settings > Visualizer > More Presets.
struct PresetPacksSection: View {
    let packs: PresetPacks

    var body: some View {
        Section {
            ForEach(PresetPack.categories) { category in
                LabeledContent {
                    if packs.loading.contains(category.name) {
                        ProgressView(value: packs.progress).frame(width: 80)
                    } else if packs.installed[category.name] != nil {
                        Button("Remove") { packs.remove(category.name) }
                    } else {
                        Button("Download") { packs.download([category.name]) }.disabled(!packs.loading.isEmpty)
                    }
                } label: {
                    Text(category.name)
                    Text("\(category.count) presets").foregroundStyle(.secondary)
                }
            }
            HStack {
                let missing = Set(PresetPack.categories.map(\.name)).subtracting(packs.installed.keys)
                Button("Download All") { packs.download(missing) }.disabled(missing.isEmpty || !packs.loading.isEmpty)
                if !packs.loading.isEmpty { Button("Cancel") { packs.cancel() } }
            }
            if let error = packs.error { Text(error).foregroundStyle(.red) }
        } header: {
            Text("More Presets")
        } footer: {
            SettingsFooter("The Cream of the Crop pack from projectM, 9,795 presets sorted by theme. Each download fetches the whole pack (about 20 MB) and keeps the chosen themes.")
        }
    }
}
