import Foundation
import MilkDropKit
import Support
import SwiftUI

/// MilkDrop presets, rendered natively by `MilkDropKit` from the tap's samples.
typealias MilkDrop = MilkDropController

extension MilkDropController {
    /// The user's presets: `.milk` files (imported, or put there by hand), and images they name.
    nonisolated static var userFolder: URL { Paths.appSupport("Visualizer Presets") }
    /// Packs downloaded in Settings > Visualizer, one folder per category.
    nonisolated static var downloadedFolder: URL { userFolder.appendingPathComponent("Downloaded", isDirectory: true) }

    /// Pictures of the presets on the demo track, for the preset browser.
    nonisolated static var thumbnailFolder: URL { Paths.caches("MilkDrop", "Thumbnails") }
    /// Which presets compile and which do not (`CompileIndex`).
    nonisolated static var compileIndex: URL { Paths.caches("MilkDrop").appendingPathComponent("compiled.json") }
    /// What the demo track showed of each preset: look, mood and flashes (`PresetMeasures`).
    nonisolated static var measuresFile: URL { Paths.caches("MilkDrop").appendingPathComponent("measures.json") }
    nonisolated static var presetFolders: [URL] { [downloadedFolder, userFolder] }

    static func app() -> MilkDropController {
        MilkDropController(folders: presetFolders, textureFolders: [userFolder], index: compileIndex, measures: measuresFile)
    }

    /// Compiles and measures presets ahead in the background; one for the whole app.
    @MainActor static let precompiler = PresetPrecompiler(folders: presetFolders, index: compileIndex,
                                                          thumbnails: thumbnailFolder, textureFolders: [userFolder], measures: measuresFile)

    /// Reads the presets folders again. Butterchurn `.json` files that an earlier version converted from a `.milk`
    /// next to them are deleted: the native renderer reads the `.milk` itself.
    func loadUserPresets() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.userFolder, includingPropertiesForKeys: nil)) ?? []
        let milk = Set(files.filter { $0.pathExtension == "milk" }.map { $0.deletingPathExtension().lastPathComponent })
        for file in files where file.pathExtension == "json" && milk.contains(file.deletingPathExtension().lastPathComponent) {
            try? fm.removeItem(at: file)
        }
        reload()
    }
}

struct MilkDropView: View {
    let player: Player
    let milkDrop: MilkDrop

    var body: some View {
        MilkDropSurface(milkDrop)
            .onAppear { milkDrop.samples = Self.samples(player) }
    }

    /// The samples that play now, from the player's tap.
    static func samples(_ player: Player) -> () -> (left: [Float], right: [Float], rate: Double) {
        { [player] in
            let tap = player.mixer.equalizer.samples
            let s = tap.latest(AudioLevels.sampleCount, at: player.mixer.time)
            return (s.left, s.right, tap.sampleRate)
        }
    }
}
