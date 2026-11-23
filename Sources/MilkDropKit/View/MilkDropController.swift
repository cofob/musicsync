import Foundation
import MetalKit
import Observation

/// Runs the visualizer for a view: which preset shows, timed and random changes, the next preset compiled ahead,
/// and one frame per draw. Presets that do not parse or compile leave the list (`failed`).
@Observable @MainActor public final class MilkDropController: MilkDropDrawing {
    public private(set) var presets: [String] = []
    public private(set) var current: String?
    public private(set) var failed: [String] = []
    /// The samples that play now and their rate; silence when nil.
    @ObservationIgnored public var samples: (() -> (left: [Float], right: [Float], rate: Double))?

    @ObservationIgnored private var library: PresetLibrary
    @ObservationIgnored private var cycler = PresetCycler()
    @ObservationIgnored private var renderer: Renderer?
    @ObservationIgnored private var compiled: [String: CompiledPreset] = [:]
    @ObservationIgnored private var compiling: Set<String> = []
    /// The change to show once its preset has compiled.
    @ObservationIgnored private var waiting: PresetCycler.Change?
    @ObservationIgnored private var pendingTitle: (String, Double)?
    @ObservationIgnored private let folders: [URL]
    @ObservationIgnored private let textureFolders: [URL]
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private let start = ContinuousClock.now

    /// `folders`: preset folders besides the bundled ones (searched one level deep), later ones win on equal names.
    public init(folders: [URL] = [], textureFolders: [URL] = []) {
        self.folders = folders
        self.textureFolders = textureFolders
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
        updateNames()
    }

    public func step(_ by: Int) { apply(cycler.step(by, now: now)) }
    public func random() { apply(cycler.random(now: now)) }
    public func select(_ name: String) { apply(cycler.select(name, now: now)) }

    /// MilkDrop's song title animation; the text flies in and melts into the picture.
    public func title(_ text: String, seconds: Double = 4) {
        guard let renderer else { pendingTitle = (text, seconds); return }
        renderer.showTitle(text, seconds: seconds)
    }

    private func updateNames() {
        cycler.setNames(library.names(includingBuiltIn: cycler.options.builtIn, excluding: Set(failed)))
        presets = cycler.names
        prepare(cycler.upcoming)
    }

    // MARK: Changes

    private func apply(_ change: PresetCycler.Change?) {
        guard let change else { return }
        if let ready = compiled[change.name], let renderer {
            show(ready, change, renderer)
        } else {
            waiting = change
            prepare(change.name)
        }
    }

    private func show(_ preset: CompiledPreset, _ change: PresetCycler.Change, _ renderer: Renderer) {
        do {
            try renderer.show(preset, blend: current == nil ? 0 : change.blend)
            current = change.name
            waiting = nil
            compiled = compiled.filter { $0.key == change.name || $0.key == cycler.upcoming }
            prepare(cycler.upcoming)
        } catch {
            fail(change.name)
        }
    }

    /// Parses and compiles `name` off the main thread.
    private func prepare(_ name: String?) {
        guard let name, compiled[name] == nil, !compiling.contains(name), let entry = library.entries[name],
              let device = renderer?.device ?? MTLCreateSystemDefaultDevice() else { return }
        compiling.insert(name)
        Task.detached(priority: .utility) {
            let result = try? await CompiledPreset.compile(PresetFile.load(entry.url), device: device, screenFormat: Self.screenFormat)
            await self.compiled(name, result)
        }
    }

    private func compiled(_ name: String, _ result: CompiledPreset?) {
        compiling.remove(name)
        guard let result else { return fail(name) }
        compiled[name] = result
        if waiting?.name == name, let waiting, let renderer { show(result, waiting, renderer) }
    }

    private func fail(_ name: String) {
        if !failed.contains(name) { failed.append(name) }
        compiled[name] = nil
        let next = cycler.drop(name, now: now)
        presets = cycler.names
        if waiting?.name == name { waiting = nil }
        apply(next)
        prepare(cycler.upcoming)
    }

    // MARK: Drawing

    nonisolated static let screenFormat = MTLPixelFormat.bgra8Unorm

    public func draw(in view: MTKView) {
        guard let device = view.device else { return }
        if renderer == nil {
            renderer = Renderer(device: device, textureFolders: textureFolders)
            if let (text, seconds) = pendingTitle { renderer?.showTitle(text, seconds: seconds); pendingTitle = nil }
        }
        guard let renderer else { return }
        if current == nil, waiting == nil { random() }
        apply(cycler.tick(now: now))
        guard renderer.current != nil, let drawable = view.currentDrawable, let buffer = renderer.queue.makeCommandBuffer() else { return }
        let scale = view.bounds.width > 0 ? Double(view.drawableSize.width / view.bounds.width) : 1
        let quality = min(cycler.options.quality, scale)
        let size = SIMD2(Int(Double(view.drawableSize.width) / scale * quality), Int(Double(view.drawableSize.height) / scale * quality))
        let audio = samples?() ?? (left: [], right: [], rate: 44100)
        renderer.render(into: drawable.texture, buffer: buffer, size: Self.capped(size), left: audio.left, right: audio.right,
                        sampleRate: audio.rate, now: now)
        buffer.present(drawable)
        buffer.commit()
    }

    public func sizeChanged(_ size: CGSize, in view: MTKView) {}

    /// At most 2048 px on the longer side: more costs GPU time and memory for little gain.
    static func capped(_ size: SIMD2<Int>) -> SIMD2<Int> {
        let longer = max(size.x, size.y)
        guard longer > 2048 else { return size }
        return SIMD2(size.x * 2048 / longer, size.y * 2048 / longer)
    }
}
