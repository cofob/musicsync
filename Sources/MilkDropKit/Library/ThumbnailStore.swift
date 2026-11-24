import CoreGraphics
import Foundation
import Metal
import Synchronization

/// Preset pictures for the preset browser: from memory, from disk, or made on demand (two at a time, so scrolling
/// stays smooth; a picture whose card scrolled away before its turn is not made). A preset shown without its
/// measures (`PresetMeasures`) gets them made then.
public final class ThumbnailStore: Sendable {
    private let thumbnails: PresetThumbnails
    private let index: CompileIndex?
    private let measures: PresetMeasures?
    private let memory = Mutex<[String: CGImage]>([:])
    private let limiter = AsyncLimiter(2)
    private let gpuState = Mutex<(MTLDevice, Noise.Textures)?>(nil)

    public init(folder: URL, index: URL?, textureFolders: [URL] = [], measures: URL? = nil) {
        thumbnails = PresetThumbnails(folder: folder, textureFolders: textureFolders)
        self.index = index.map(CompileIndex.at)
        self.measures = measures.map(PresetMeasures.at)
    }

    /// The picture of `entry`, nil when it does not compile or the caller's task was cancelled.
    public func thumbnail(_ entry: PresetLibrary.Entry) async -> CGImage? {
        let key = entry.url.path
        let measured = isMeasured(entry)
        if measured, let image = memory.withLock({ $0[key] }) { return image }
        if measured, let image = thumbnails.cached(entry) { return remember(image, key) }
        guard index?.status(entry) != false else { return nil }
        await limiter.wait()
        defer { Task { await limiter.signal() } }
        guard !Task.isCancelled, let (device, noise) = gpu() else { return nil }
        let made = isMeasured(entry)
        if made, let image = thumbnails.cached(entry) { return remember(image, key) }  // made while waiting
        do {
            let compiled = try await CompiledPreset.compile(PresetFile.load(entry.url), device: device, screenFormat: MilkDropController.screenFormat)
            index?.record(entry, ok: true)
            if let measures, !made {
                measures.record(entry, try PresetMeasurer.measure(compiled, device: device, noise: noise))
                measures.save()
            }
            if let image = thumbnails.cached(entry) { return remember(image, key) }
            return remember(try thumbnails.make(compiled, entry: entry, device: device, noise: noise), key)
        } catch {
            index?.record(entry, ok: false, error: String(describing: error).prefix(200).description)
            index?.save()
            return nil
        }
    }

    /// Nothing to measure, or measured already.
    private func isMeasured(_ entry: PresetLibrary.Entry) -> Bool { measures == nil || measures?.measure(entry) != nil }

    private func remember(_ image: CGImage, _ key: String) -> CGImage {
        memory.withLock { cache in
            if cache.count > 600 { cache.removeAll() }  // about 90 MB of pictures at most
            cache[key] = image
        }
        return image
    }

    private func gpu() -> (MTLDevice, Noise.Textures)? {
        gpuState.withLock { value in
            if let value { return value }
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let noise = Noise.makeTextures(device: device, queue: queue) else { return nil }
            value = (device, noise)
            return value
        }
    }
}

/// At most `count` callers between `wait` and `signal`.
actor AsyncLimiter {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { free = count }

    func wait() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func signal() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}
