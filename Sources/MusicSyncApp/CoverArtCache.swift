import AppKit
import ImageIO
import Library
import Subsonic
import Support

/// Cover art in memory (NSCache) and on disk (`Caches/MusicSync/covers/<account>`).
actor CoverArtCache {
    private let client: SubsonicClient
    private let directory: URL
    /// Covers kept with the downloads (600 px); used when the cache has no file of the size.
    private let offline: URL?
    // NSCache is thread-safe.
    private nonisolated(unsafe) let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]
    /// Cover id (file-name form) -> pixel sizes saved on disk. Read on first use, off the main thread that creates the cache.
    private lazy var sizesOnDisk: [String: Set<Int>] = Self.sizes(in: directory)

    init(client: SubsonicClient, offline: URL? = nil) {
        self.client = client
        self.offline = offline
        directory = Paths.caches("covers", client.config.account)
        memory.countLimit = 500
        memory.totalCostLimit = 32 << 20
    }

    private static func sizes(in directory: URL) -> [String: Set<Int>] {
        var sizes: [String: Set<Int>] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard let at = name.lastIndex(of: "@"), let size = Int(name[name.index(after: at)...]) else { continue }
            sizes[String(name[..<at]), default: []].insert(size)
        }
        return sizes
    }

    /// Decodes at most `size` px on the long edge, so only the bitmap stays in memory (no file bytes, no oversize).
    private static func decode(_ source: CGImageSource?, _ size: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func decode(_ url: URL, _ size: Int) -> NSImage? { decode(CGImageSourceCreateWithURL(url as CFURL, nil), size) }

    private static func decode(_ data: Data, _ size: Int) -> NSImage? { decode(CGImageSourceCreateWithData(data as CFData, nil), size) }

    private nonisolated func keep(_ image: NSImage, _ key: String) {
        memory.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height) * 4)
    }

    /// Drops every cover from memory (the main window closed).
    nonisolated func purge() { memory.removeAllObjects() }

    private static func fileID(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "_") }

    /// Best full cover already on disk for `size`: the smallest one at least that big, else the biggest one.
    /// `exact` is false when only a smaller one exists (show it, then load the right size).
    func local(id: String, size: Int) -> (image: NSImage, exact: Bool)? {
        let sizes = sizesOnDisk[Self.fileID(id)] ?? []
        guard let best = sizes.filter({ $0 >= size }).min() ?? sizes.max() else { return offlineCover(id: id, size: size) }
        let target = min(size, best)
        let key = "\(id)@\(target)"
        let image = memory.object(forKey: key as NSString)
            ?? Self.decode(directory.appendingPathComponent("\(Self.fileID(id))@\(best)"), target)
        guard let image else { return nil }
        keep(image, key)
        return (image, best >= size)
    }

    /// Image already in memory; lets a view show it in its first frame.
    nonisolated func cached(id: String, size: Int) -> NSImage? { memory.object(forKey: "\(id)@\(size)" as NSString) }

    /// Local thumbnail file (the mirror's 96 px covers), kept in memory under `<key>@small`.
    func image(file: URL, key: String) -> NSImage? {
        let memoryKey = "\(key)@small" as NSString
        if let hit = memory.object(forKey: memoryKey) { return hit }
        guard let image = Self.decode(file, 96) else { return nil }
        keep(image, memoryKey as String)
        return image
    }

    /// `size` is the requested edge in pixels.
    func image(id: String, size: Int) async -> NSImage? {
        let key = "\(id)@\(size)"
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let local = local(id: id, size: size), local.exact { return local.image }
        let file = directory.appendingPathComponent("\(Self.fileID(id))@\(size)")
        let data: Data?
        if let cached = try? Data(contentsOf: file) {
            data = cached
        } else {
            data = await download(key: key, id: id, size: size, to: file)
        }
        guard let data, let image = Self.decode(data, size) else { return local(id: id, size: size)?.image }
        sizesOnDisk[Self.fileID(id), default: []].insert(size)
        keep(image, key)
        return image
    }

    private func offlineCover(id: String, size: Int) -> (image: NSImage, exact: Bool)? {
        let key = "\(id)@offline@\(size)"
        guard let offline, let image = memory.object(forKey: key as NSString)
                ?? Self.decode(offline.appendingPathComponent(DownloadManager.coverFileName(id)), min(size, DownloadManager.coverSize))
        else { return nil }
        keep(image, key)
        return (image, size <= DownloadManager.coverSize)
    }

    private func download(key: String, id: String, size: Int, to file: URL) async -> Data? {
        if let task = inFlight[key] { return await task.value }
        let task = Task<Data?, Never> { [client] in
            guard let data = try? await client.coverArt(id: id, size: size), NSImage(data: data) != nil else { return nil }
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return await task.value
    }
}
