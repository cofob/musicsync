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
    @ObservationIgnored private let measures: PresetMeasures?

    /// `thumbnails`: where to keep a picture of each preset on the demo track, made as it compiles.
    /// `measures`: where to keep what the demo track shows of its look, mood and flashes (`PresetMeasures`).
    public init(folders: [URL], index: URL, thumbnails: URL? = nil, textureFolders: [URL] = [], measures: URL? = nil) {
        self.folders = folders
        self.index = CompileIndex.at(index)
        self.thumbnails = thumbnails.map { PresetThumbnails(folder: $0, textureFolders: textureFolders) }
        self.measures = measures.map(PresetMeasures.at)
    }

    /// Compiles every preset of the folders and the bundle not compiled yet, or only those named in `only`.
    /// `finished` runs on the main actor when it ends (also when cancelled), `progress` after every 50 presets.
    public func compileAll(only: Set<String>? = nil, finished: @escaping @MainActor () -> Void = {},
                           progress: @escaping @MainActor () -> Void = {}) {
        guard task == nil, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let noise = Noise.makeTextures(device: device, queue: queue), thumbnails = self.thumbnails, measures = self.measures
        let folders = folders, index = self.index
        (done, total, failed, isRunning) = (0, 0, 0, true)
        task = Task {
            // Off the main thread: a stat of every preset file takes seconds with thousands.
            let entries = await Task.detached(priority: .utility) {
                PresetLibrary(folders: folders).entries.values.filter { entry in
                    (only?.contains(entry.name) ?? true) && (index.status(entry) == nil || (index.status(entry) == true
                        && (thumbnails?.isCached(entry) == false || (measures != nil && measures?.measure(entry) == nil))))
                }
            }.value
            total = entries.count
            // A few at a time: the Metal compiler runs in its own processes, one per request.
            let width = max(ProcessInfo.processInfo.activeProcessorCount / 2, 2)
            await withTaskGroup(of: Bool.self) { group in
                var next = entries.makeIterator()
                func add() -> Bool {
                    guard let entry = next.next() else { return false }
                    group.addTask(priority: .utility) { await Self.compile(entry, device: device, index: index, thumbnails: thumbnails, measures: measures, noise: noise) }
                    return true
                }
                for _ in 0..<width where add() {}
                for await ok in group {
                    done += 1
                    if !ok { failed += 1 }
                    if done % 200 == 0 { Self.save(index, nil) }
                    if done % 50 == 0 { Self.save(nil, measures); progress() }
                    if Task.isCancelled { group.cancelAll(); break }
                    _ = add()
                }
            }
            await Self.save(index, measures).value
            isRunning = false
            task = nil
            finished()
        }
    }

    public func cancel() { task?.cancel() }

    /// Writes the stores off the main thread: all records as JSON take ~50 ms with thousands.
    @discardableResult private static func save(_ index: CompileIndex?, _ measures: PresetMeasures?) -> Task<Void, Never> {
        Task.detached(priority: .utility) { index?.save(); measures?.save() }
    }

    private nonisolated static func compile(_ entry: PresetLibrary.Entry, device: MTLDevice, index: CompileIndex,
                                            thumbnails: PresetThumbnails?, measures: PresetMeasures?,
                                            noise: Noise.Textures?) async -> Bool {
        do {
            let preset = try PresetFile.load(entry.url)
            // Equations too: a preset whose code does not compile cannot show either.
            _ = try PresetEquations(preset, globals: EELGlobals(), frame: FrameGlobals())
            _ = try PresetGeometry(preset, globals: EELGlobals(), frame: FrameGlobals())
            let compiled = try await CompiledPreset.compile(preset, device: device, screenFormat: MilkDropController.screenFormat)
            index.record(entry, ok: true)
            if let thumbnails, !thumbnails.isCached(entry) { try thumbnails.make(compiled, entry: entry, device: device, noise: noise) }
            if let measures, measures.measure(entry) == nil {
                measures.record(entry, try PresetMeasurer.measure(compiled, device: device, noise: noise))
            }
            return true
        } catch {
            index.record(entry, ok: false, error: String(describing: error).prefix(600).description)
            return false
        }
    }
}
