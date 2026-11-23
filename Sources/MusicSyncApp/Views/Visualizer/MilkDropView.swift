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

    /// Which presets compile and which do not (`CompileIndex`).
    nonisolated static var compileIndex: URL { Paths.caches("MilkDrop").appendingPathComponent("compiled.json") }
    nonisolated static var presetFolders: [URL] { [downloadedFolder, userFolder] }

    static func app() -> MilkDropController {
        MilkDropController(folders: presetFolders, textureFolders: [userFolder], index: compileIndex)
    }

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
            .onAppear {
                milkDrop.samples = { [player] in
                    let tap = player.mixer.equalizer.samples
                    let s = tap.latest(AudioLevels.sampleCount, at: player.mixer.time)
                    return (s.left, s.right, tap.sampleRate)
                }
            }
    }
}
