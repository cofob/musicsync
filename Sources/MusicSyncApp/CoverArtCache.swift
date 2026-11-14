import AppKit
import Subsonic
import Support

/// Cover art in memory (NSCache) and on disk (`Caches/MusicSync/covers/<account>`).
actor CoverArtCache {
    private let client: SubsonicClient
    private let directory: URL
    // NSCache is thread-safe.
    private nonisolated(unsafe) let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]
    /// Cover id (file-name form) -> pixel sizes saved on disk.
    private var sizesOnDisk: [String: Set<Int>]

    init(client: SubsonicClient) {
        self.client = client
        directory = Paths.caches("covers", client.config.account)
        memory.countLimit = 500
        var sizes: [String: Set<Int>] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard let at = name.lastIndex(of: "@"), let size = Int(name[name.index(after: at)...]) else { continue }
            sizes[String(name[..<at]), default: []].insert(size)
        }
        sizesOnDisk = sizes
    }

    private static func fileID(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "_") }

    /// Best full cover already on disk for `size`: the smallest one at least that big, else the biggest one.
    /// `exact` is false when only a smaller one exists (show it, then load the right size).
    func local(id: String, size: Int) -> (image: NSImage, exact: Bool)? {
        let sizes = sizesOnDisk[Self.fileID(id)] ?? []
        guard let best = sizes.filter({ $0 >= size }).min() ?? sizes.max() else { return nil }
        let key = "\(id)@\(best)"
        let image = memory.object(forKey: key as NSString)
            ?? NSImage(contentsOf: directory.appendingPathComponent("\(Self.fileID(id))@\(best)"))
        guard let image else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return (image, best >= size)
    }

    /// Image already in memory; lets a view show it in its first frame.
    nonisolated func cached(id: String, size: Int) -> NSImage? { memory.object(forKey: "\(id)@\(size)" as NSString) }

    /// Local thumbnail file (the mirror's 96 px covers), kept in memory under `<key>@small`.
    func image(file: URL, key: String) -> NSImage? {
        let memoryKey = "\(key)@small" as NSString
        if let hit = memory.object(forKey: memoryKey) { return hit }
        guard let image = NSImage(contentsOf: file) else { return nil }
        memory.setObject(image, forKey: memoryKey)
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
        guard let data, let image = NSImage(data: data) else { return nil }
        sizesOnDisk[Self.fileID(id), default: []].insert(size)
        memory.setObject(image, forKey: key as NSString)
        return image
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
