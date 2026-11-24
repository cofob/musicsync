import Foundation
import Metal
import Observation

/// Compiles presets ahead of time, in the background: their shaders land in the system's Metal shader cache (so they
/// show at once later) and their result in the `CompileIndex` (so presets that do not compile leave the list).
@Observable @MainActor public final class PresetPrecompiler {
    public private(set) var done = 0
    public private(set) var total = 0
    public private(set) var failed = 0
    public private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let folders: [URL]
    @ObservationIgnored private let index: CompileIndex
    @ObservationIgnored private let thumbnails: PresetThumbnails?

    /// `thumbnails`: where to keep a picture of each preset on the demo track, made as it compiles.
    public init(folders: [URL], index: URL, thumbnails: URL? = nil, textureFolders: [URL] = []) {
        self.folders = folders
        self.index = CompileIndex.at(index)
        self.thumbnails = thumbnails.map { PresetThumbnails(folder: $0, textureFolders: textureFolders) }
    }

    /// Compiles every preset of the folders and the bundle not compiled yet, or only those named in `only`.
    /// `finished` runs on the main actor when it ends (also when cancelled).
    public func compileAll(only: Set<String>? = nil, finished: @escaping @MainActor () -> Void = {}) {
        guard task == nil, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let noise = Noise.makeTextures(device: device, queue: queue), thumbnails = self.thumbnails
        let library = PresetLibrary(folders: folders)
        let index = self.index
        let entries = library.entries.values.filter { entry in
            (only?.contains(entry.name) ?? true) && (index.status(entry) == nil || (index.status(entry) == true && thumbnails?.cached(entry) == nil))
        }
        (done, total, failed, isRunning) = (0, entries.count, 0, true)
        task = Task {
            // A few at a time: the Metal compiler runs in its own processes, one per request.
            let width = max(ProcessInfo.processInfo.activeProcessorCount / 2, 2)
            await withTaskGroup(of: Bool.self) { group in
                var next = entries.makeIterator()
                func add() -> Bool {
                    guard let entry = next.next() else { return false }
                    group.addTask(priority: .utility) { await Self.compile(entry, device: device, index: index, thumbnails: thumbnails, noise: noise) }
                    return true
                }
                for _ in 0..<width where add() {}
                for await ok in group {
                    done += 1
                    if !ok { failed += 1 }
                    if done % 200 == 0 { index.save() }
                    if Task.isCancelled { group.cancelAll(); break }
                    _ = add()
                }
            }
            index.save()
            isRunning = false
            task = nil
            finished()
        }
    }

    public func cancel() { task?.cancel() }

    private nonisolated static func compile(_ entry: PresetLibrary.Entry, device: MTLDevice, index: CompileIndex,
                                            thumbnails: PresetThumbnails?, noise: Noise.Textures?) async -> Bool {
        do {
            let preset = try PresetFile.load(entry.url)
            // Equations too: a preset whose code does not compile cannot show either.
            _ = try PresetEquations(preset, globals: EELGlobals(), frame: FrameGlobals())
            _ = try PresetGeometry(preset, globals: EELGlobals(), frame: FrameGlobals())
            let compiled = try await CompiledPreset.compile(preset, device: device, screenFormat: MilkDropController.screenFormat)
            index.record(entry, ok: true)
            if let thumbnails, thumbnails.cached(entry) == nil { try thumbnails.make(compiled, entry: entry, device: device, noise: noise) }
            return true
        } catch {
            index.record(entry, ok: false, error: String(describing: error).prefix(600).description)
            return false
        }
    }
}
