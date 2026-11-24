import Foundation
import Support

/// The preset cache: presets made once by `scripts/preset-cache.sh` with their compile status, pictures, measures and
/// compiled shaders, so that a device does not compile and render them itself. Parts come in chunks of about 32 MB,
/// by category (`PresetCacheManifest`); a category installs with a few downloads.
public struct PresetCDN: Sendable {
    public static let defaultBase = URL(string: "https://musicsync-cache.cfb.wtf/milkdrop")!
    /// Where installed shaders are, for `CompiledPreset.compile`.
    public static let shaderFolder = Paths.caches("MilkDrop", "Shaders", "r\(PresetCacheFormat.renderer)")
    #if os(macOS)
    public static let platform = "macos"
    #else
    public static let platform = "ios"
    #endif

    public var base: URL
    public var session: URLSession

    public init(base: URL = PresetCDN.defaultBase, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    /// Where `install` puts things.
    public struct Places: Sendable {
        /// `.milk` files go to `<downloads>/<category>/`.
        public var downloads: URL
        public var thumbnails: URL
        /// `CompileIndex` and `PresetMeasures` files.
        public var index: URL, measures: URL
        public var shaders: URL
        /// The bundled presets, which get their pictures, measures and shaders when they match the cache's.
        public var builtIn: URL?

        public init(downloads: URL, thumbnails: URL, index: URL, measures: URL, shaders: URL = PresetCDN.shaderFolder,
                    builtIn: URL? = MilkDropResources.presets) {
            (self.downloads, self.thumbnails, self.index, self.measures, self.shaders, self.builtIn) = (downloads, thumbnails, index, measures, shaders, builtIn)
        }
    }

    public func index() async throws -> PresetCacheIndex {
        try JSONDecoder().decode(PresetCacheIndex.self, from: await get("index.json"))
    }

    /// The newest set for `renderer`; nil when the cache has none.
    public func manifest(renderer: Int = PresetCacheFormat.renderer) async throws -> PresetCacheManifest? {
        let index = try await index()
        guard index.format == PresetCacheFormat.format, let id = index.latest[String(renderer)],
              let dataset = index.datasets.first(where: { $0.id == id }) else { return nil }
        let manifest = try JSONDecoder().decode(PresetCacheManifest.self, from: TarGzip.gunzip(await get(dataset.manifest)))
        return manifest.format == PresetCacheFormat.format && manifest.renderer == renderer ? manifest : nil
    }

    /// Categories of the cache's pack presets, with their counts and download sizes.
    public static func categories(_ manifest: PresetCacheManifest) -> [PresetPack.Category] {
        let counts = Dictionary(grouping: manifest.presets.filter { $0.pack != "builtin" }, by: \.category).mapValues(\.count)
        let bytes = manifest.bytes()
        return counts.keys.sorted().map { PresetPack.Category(name: $0, count: counts[$0]!, bytes: bytes[$0]) }
    }

    /// Installs the presets of `categories` (`PresetLibrary.builtInCategory` for the bundled ones), each chunk
    /// downloaded whole, once, and checked. Presets installed already are left. `progress` gets 0…1.
    /// Returns how many presets it installed.
    @discardableResult
    public func install(_ categories: Set<String>, from manifest: PresetCacheManifest, into places: Places,
                        progress: @Sendable (Double) -> Void = { _ in }) async throws -> Int {
        let index = CompileIndex.at(places.index), measures = PresetMeasures.at(places.measures)
        let thumbnails = PresetThumbnails(folder: places.thumbnails)
        let builtIn = PresetLibrary(builtIn: places.builtIn, folders: []).entries
        let fm = FileManager.default
        func done(_ local: PresetLibrary.Entry) -> Bool {
            fm.fileExists(atPath: local.url.path) && index.status(local) != nil && (index.status(local) == false
                || (measures.measure(local) != nil && fm.fileExists(atPath: thumbnails.url(local).path)))
        }
        var targets: [(entry: PresetCacheManifest.Entry, local: PresetLibrary.Entry)] = []
        for entry in manifest.presets where categories.contains(entry.category) {
            if entry.pack == "builtin" {
                guard let local = builtIn[entry.name], !done(local),
                      (try? Data(contentsOf: local.url)).map(PresetCacheManifest.sha256) == entry.sha256 else { continue }
                targets.append((entry, local))
            } else {
                let url = places.downloads.appendingPathComponent(entry.category).appendingPathComponent(entry.name + ".milk")
                let local = PresetLibrary.Entry(name: entry.name, url: url, isBuiltIn: false, category: entry.category)
                if !done(local) { targets.append((entry, local)) }
            }
        }
        // What to write from each chunk; the `.milk` files first, since the other files are named by them.
        var jobs: [String: [(part: PresetCacheManifest.Part, file: () -> URL, mtime: Double?)]] = [:]
        func add(_ part: PresetCacheManifest.Part?, _ file: @escaping @autoclosure () -> URL, mtime: Double? = nil) { part.map { jobs[$0.chunk, default: []].append(($0, file, mtime)) } }
        let stages = ["warp", "comp"].map { ($0, "\($0).\(Self.platform)") }
        for (entry, local) in targets {
            if entry.pack != "builtin" { add(entry.parts["milk"], local.url, mtime: entry.mtime) }
            guard entry.status.ok else { continue }
            add(entry.parts["thumb"], thumbnails.url(local))
            for (stage, kind) in stages where entry.parts[kind] != manifest.defaults[kind] {
                add(entry.parts[kind], places.shaders.appendingPathComponent("\(entry.sha256)-\(stage).metallib"))
                if let info = entry.shaders?[stage] { CompiledPreset.save(info, "\(entry.sha256)-\(stage)", in: places.shaders) }
            }
        }
        if targets.contains(where: \.entry.status.ok) {
            for (stage, kind) in stages {
                let file = places.shaders.appendingPathComponent("default-\(stage).metallib")
                if !fm.fileExists(atPath: file.path) { add(manifest.defaults[kind], file) }
            }
        }
        let order = manifest.chunks.filter { jobs[$0.id] != nil }.sorted { ($0.group.hasPrefix("milk/") ? 0 : 1) < ($1.group.hasPrefix("milk/") ? 0 : 1) }
        for (n, chunk) in order.enumerated() {
            let data = try await get("chunks/\(chunk.id).bin")
            guard PresetCacheManifest.sha256(data) == chunk.id else { throw CocoaError(.fileReadCorruptFile) }
            for job in jobs[chunk.id] ?? [] {
                let file = job.file()
                guard job.part.offset + job.part.length <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.subdata(in: job.part.offset..<job.part.offset + job.part.length).write(to: file, options: .atomic)
                if let mtime = job.mtime { try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: file.path) }
            }
            progress(Double(n + 1) / Double(order.count))
        }
        for (entry, local) in targets {
            index.record(local, ok: entry.status.ok, error: entry.status.error)
            if let look = entry.look, let flash = entry.flash { measures.record(local, PresetMeasure(look: look, flash: flash)) }
        }
        index.save()
        measures.save()
        progress(1)
        return targets.count
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(from: base.appendingPathComponent(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
