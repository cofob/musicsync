import MilkDropKit
import SwiftUI

/// Downloads of the "Cream of the Crop" preset pack, by category, into `MilkDrop.downloadedFolder`: from the preset
/// cache, ready to show, or else from GitHub, and then new presets compile ahead in the background.
@Observable @MainActor final class PresetPacks {
    let compiler = MilkDrop.precompiler
    private(set) var installed: [String: Int] = [:]
    /// Categories being downloaded and the download's progress (0…1).
    private(set) var loading: Set<String> = []
    private(set) var progress = 0.0
    private(set) var error: String?
    /// The preset cache's set (`PresetCDN`), nil until it comes or when there is none.
    private(set) var cache: PresetCacheManifest?
    var categories: [PresetPack.Category] { cache.map(PresetCDN.categories) ?? PresetPack.categories }
    private var task: Task<Void, Never>?

    func refresh() {
        installed = PresetPack.installed(in: MilkDrop.downloadedFolder)
        if cache == nil { Task { cache = await MilkDrop.cachedPresets() } }
    }

    /// One download at a time: the archive holds all categories.
    func download(_ categories: Set<String>) {
        guard task == nil, !categories.isEmpty else { return }
        loading = categories
        progress = 0
        error = nil
        task = Task {
            do {
                let progress: @Sendable (Double) -> Void = { value in Task { @MainActor in self.progress = value } }
                if let manifest = await MilkDrop.cachedPresets(ask: true) {
                    try await PresetCDN().install(categories, from: manifest, into: MilkDrop.cachePlaces, progress: progress)
                } else if await NetworkConsent.request(.presetArchive) {
                    _ = try await PresetPack.download(categories, to: MilkDrop.downloadedFolder, progress: progress)
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            loading = []
            task = nil
            changed()
            compileAll()
        }
    }

    func cancel() { task?.cancel() }

    /// Compiles every preset not compiled yet; presets that do not compile leave the visualizer's list.
    func compileAll() { compiler.compileAll { [weak self] in self?.changed() } }

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
            ForEach(packs.categories) { category in
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
                    Text("\(category.count) presets" + (category.bytes.map { ", " + $0.formatted(.byteCount(style: .file)) } ?? ""))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                let missing = Set(packs.categories.map(\.name)).subtracting(packs.installed.keys)
                Button("Download All") { packs.download(missing) }.disabled(missing.isEmpty || !packs.loading.isEmpty)
                if !packs.loading.isEmpty { Button("Cancel") { packs.cancel() } }
            }
            if let error = packs.error { Text(error).foregroundStyle(.red) }
            CompileAllRow(compiler: packs.compiler) { packs.compileAll() }
        } header: {
            Text("More Presets")
        } footer: {
            SettingsFooter("The Cream of the Crop pack from projectM, 9,795 presets sorted by theme. Presets come ready to show, with their pictures and measures; when that cannot be reached, each download fetches the whole pack (about 20 MB) and keeps the chosen themes. Compile All prepares every preset ahead, so it shows at once; downloaded presets compile on their own. Presets that do not compile are left out.")
        }
    }
}

/// "Compile All Presets" with its progress.
private struct CompileAllRow: View {
    let compiler: PresetPrecompiler
    let start: () -> Void

    var body: some View {
        if compiler.isRunning {
            LabeledContent {
                HStack {
                    ProgressView(value: Double(compiler.done), total: Double(max(compiler.total, 1))).frame(width: 80)
                    Button("Stop") { compiler.cancel() }
                }
            } label: {
                Text("Compiling presets")
                Text("\(compiler.done) of \(compiler.total)").foregroundStyle(.secondary)
            }
        } else {
            LabeledContent {
                Button("Compile All Presets", action: start)
            } label: {
                Text("Compile ahead")
                if compiler.total > 0 { Text("\(compiler.done) compiled, \(compiler.failed) do not compile").foregroundStyle(.secondary) }
            }
        }
    }
}
