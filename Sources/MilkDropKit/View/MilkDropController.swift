import Foundation
import MetalKit
import Observation

/// Runs the visualizer for a view: which preset shows, timed and random changes, the next preset compiled ahead,
/// and one frame per draw. Presets that do not parse or compile leave the list (`failed`).
@Observable @MainActor public final class MilkDropController: MilkDropDrawing {
    public private(set) var presets: [String] = []
    /// The presets of `presets`, with their files and categories, for the preset browser.
    public private(set) var entries: [PresetLibrary.Entry] = []
    public private(set) var current: String?
    public private(set) var failed: [String] = []
    /// The samples that play now and their rate; silence when nil.
    @ObservationIgnored public var samples: (() -> (left: [Float], right: [Float], rate: Double))?

    @ObservationIgnored private var library: PresetLibrary
    @ObservationIgnored private var cycler = PresetCycler()
    /// Renders off the main thread; `device` and `hasRenderer` are the main thread's view of it.
    @ObservationIgnored private let loop = RenderLoop()
    @ObservationIgnored private var device: MTLDevice?
    @ObservationIgnored private var hasRenderer = false
    /// A frame is still drawing on the render queue: the next draw skips, so frames never queue up.
    @ObservationIgnored private var rendering = false
    @ObservationIgnored private var compiled: [String: CompiledPreset] = [:]
    @ObservationIgnored private var compiling: Set<String> = []
    /// The change to show once its preset has compiled.
    @ObservationIgnored private var waiting: PresetCycler.Change?
    @ObservationIgnored private var pendingTitle: (String, Double)?
    @ObservationIgnored private let folders: [URL]
    @ObservationIgnored private let textureFolders: [URL]
    @ObservationIgnored private let index: CompileIndex?
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let start = ContinuousClock.now

    /// `folders`: preset folders besides the bundled ones (searched one level deep), later ones win on equal names.
    /// `index`: where to keep which presets compile (`CompileIndex`), so broken ones stay out from the start.
    public init(folders: [URL] = [], textureFolders: [URL] = [], index: URL? = nil) {
        self.folders = folders
        self.textureFolders = textureFolders
        self.index = index.map(CompileIndex.at)
        library = PresetLibrary(folders: folders)
        reload()
    }

    private var now: Double { let d = clock.now - start; return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18 }

    public func configure(_ options: PresetCycler.Options) {
        let lists = options.builtIn != cycler.options.builtIn
        cycler.setOptions(options)
        if lists { updateNames() }
    }

    /// Reads the folders again (new or removed presets).
    public func reload() {
        library = PresetLibrary(folders: folders)
        if let index { failed = Array(Set(failed).union(index.failed(in: library))).sorted() }
        updateNames()
    }

    public func step(_ by: Int) { apply(cycler.step(by, now: now)) }
    public func random() { apply(cycler.random(now: now)) }
    public func select(_ name: String) { apply(cycler.select(name, now: now)) }

    /// MilkDrop's song title animation; the text flies in and melts into the picture.
    public func title(_ text: String, seconds: Double = 4) {
        guard hasRenderer else { pendingTitle = (text, seconds); return }
        let loop = loop
        loop.queue.async { loop.renderer?.showTitle(text, seconds: seconds) }
    }

    private func updateNames() {
        cycler.setNames(library.names(includingBuiltIn: cycler.options.builtIn, excluding: Set(failed)))
        presets = cycler.names
        entries = presets.compactMap { library.entries[$0] }
        prepare(cycler.upcoming)
    }

    // MARK: Changes

    private func apply(_ change: PresetCycler.Change?) {
        guard let change else { return }
        if let ready = compiled[change.name], hasRenderer {
            show(ready, change)
        } else {
            waiting = change
            prepare(change.name)
        }
    }

    private func show(_ preset: CompiledPreset, _ change: PresetCycler.Change) {
        let name = change.name, blend = current == nil ? 0 : change.blend, loop = loop
        current = name
        waiting = nil
        compiled = compiled.filter { $0.key == name || $0.key == cycler.upcoming }
        prepare(cycler.upcoming)
        // In order with the frames; equations that do not compile drop the preset.
        loop.queue.async {
            do { try loop.renderer?.show(preset, blend: blend) } catch { Task { @MainActor in self.fail(name) } }
        }
    }

    /// Parses and compiles `name` off the main thread.
    private func prepare(_ name: String?) {
        guard let name, compiled[name] == nil, !compiling.contains(name), let entry = library.entries[name],
              let device = device ?? MTLCreateSystemDefaultDevice() else { return }
        compiling.insert(name)
        Task.detached(priority: .utility) {
            let result = try? await CompiledPreset.compile(PresetFile.load(entry.url), device: device, screenFormat: Self.screenFormat)
            await self.compiled(name, result)
        }
    }

    private func compiled(_ name: String, _ result: CompiledPreset?) {
        compiling.remove(name)
        if let entry = library.entries[name], let index {
            index.record(entry, ok: result != nil)
            index.save()
        }
        guard let result else { return fail(name) }
        compiled[name] = result
        if waiting?.name == name, let waiting, hasRenderer { show(result, waiting) }
    }

    private func fail(_ name: String) {
        if !failed.contains(name) { failed.append(name) }
        compiled[name] = nil
        let next = cycler.drop(name, now: now)
        presets = cycler.names
        entries.removeAll { $0.name == name }
        if waiting?.name == name { waiting = nil }
        apply(next)
        prepare(cycler.upcoming)
    }

    // MARK: Drawing

    nonisolated static let screenFormat = MTLPixelFormat.bgra8Unorm

    /// On the main thread only the preset changes and the audio snapshot; the frame renders on `loop.queue`.
    public func draw(in view: MTKView) {
        guard let device = view.device, !rendering else { return }
        let loop = loop
        if !hasRenderer {
            hasRenderer = true
            self.device = device
            let folders = textureFolders
            loop.queue.async { loop.renderer = Renderer(device: device, textureFolders: folders) }
            if let (text, seconds) = pendingTitle { pendingTitle = nil; title(text, seconds: seconds) }
        }
        if current == nil, waiting == nil { random() }
        apply(cycler.tick(now: now))
        guard current != nil, let metalLayer = view.layer as? CAMetalLayer else { return }
        let scale = view.bounds.width > 0 ? Double(view.drawableSize.width / view.bounds.width) : 1
        let quality = min(cycler.options.quality, scale)
        let size = Self.capped(SIMD2(Int(Double(view.drawableSize.width) / scale * quality), Int(Double(view.drawableSize.height) / scale * quality)))
        let audio = samples?() ?? (left: [], right: [], rate: 44100)
        let time = now
        nonisolated(unsafe) let layer = metalLayer  // only `nextDrawable()`, which any thread may call
        rendering = true
        loop.queue.async {
            defer { Task { @MainActor in self.rendering = false } }
            guard let renderer = loop.renderer, let drawable = layer.nextDrawable(), let buffer = renderer.queue.makeCommandBuffer() else { return }
            renderer.render(into: drawable.texture, buffer: buffer, size: size, left: audio.left, right: audio.right,
                            sampleRate: audio.rate, now: time)
            buffer.present(drawable)
            buffer.commit()
        }
    }

    public func sizeChanged(_ size: CGSize, in view: MTKView) {}

    /// At most 2048 px on the longer side: more costs GPU time and memory for little gain.
    static func capped(_ size: SIMD2<Int>) -> SIMD2<Int> {
        let longer = max(size.x, size.y)
        guard longer > 2048 else { return size }
        return SIMD2(size.x * 2048 / longer, size.y * 2048 / longer)
    }
}

/// The renderer and all its state, used only on `queue`: its CPU work (equations, meshes, encoding) would
/// otherwise take the main thread at every frame.
private final class RenderLoop: @unchecked Sendable {
    let queue = DispatchQueue(label: "MilkDrop.render", qos: .userInteractive)
    var renderer: Renderer?
}
