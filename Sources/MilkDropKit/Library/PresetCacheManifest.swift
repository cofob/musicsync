import CryptoKit
import Foundation

/// `index.json` of the preset cache: the sets in it, and the newest for each renderer version.
public struct PresetCacheIndex: Codable, Equatable, Sendable {
    public struct Dataset: Codable, Equatable, Sendable {
        public var id: String
        public var renderer: Int
        public var created: String
        /// Path of `manifest.json.gz`, from the cache's root.
        public var manifest: String
        public var presets: Int
        public var bytes: Int

        public init(id: String, renderer: Int, created: String, manifest: String, presets: Int, bytes: Int) {
            (self.id, self.renderer, self.created, self.manifest, self.presets, self.bytes) = (id, renderer, created, manifest, presets, bytes)
        }
    }

    public var format = PresetCacheFormat.format
    public var datasets: [Dataset] = []
    /// Renderer version ("1") → dataset id.
    public var latest: [String: String] = [:]

    public init() {}
}

/// One set of the preset cache: every preset with its compile status and measures, and where its parts are in the
/// chunks (`chunks/<sha256>.bin`, which are just the parts one after another).
public struct PresetCacheManifest: Codable, Equatable, Sendable {
    public struct Part: Codable, Hashable, Sendable {
        public var chunk: String
        public var offset: Int
        public var length: Int
        public var sha256: String
    }

    public struct Status: Codable, Equatable, Sendable {
        public var ok: Bool
        /// `CompiledPreset.fallbacks`.
        public var fallbacks: [String] = []
        /// Equation blocks left out (`EELScope.skipped`).
        public var skipped: [String] = []
        public var error: String?

        public init(ok: Bool, fallbacks: [String] = [], skipped: [String] = [], error: String? = nil) {
            (self.ok, self.fallbacks, self.skipped, self.error) = (ok, fallbacks, skipped, error)
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        /// "builtin" or "cream-of-the-crop".
        public var pack: String
        public var category: String
        /// Of the `.milk` file.
        public var sha256: String
        public var size: Int
        public var mtime: Double
        public var status: Status
        public var look: PresetLook?
        public var flash: FlashReport?
        /// "milk", "thumb", "warp.macos", "comp.macos", "warp.ios", "comp.ios". A stage on the default shader has the
        /// part of `defaults`.
        public var parts: [String: Part]

        public init(name: String, pack: String, category: String, sha256: String, size: Int, mtime: Double, status: Status,
                    look: PresetLook?, flash: FlashReport?, parts: [String: Part]) {
            (self.name, self.pack, self.category, self.sha256, self.size, self.mtime) = (name, pack, category, sha256, size, mtime)
            (self.status, self.look, self.flash, self.parts) = (status, look, flash, parts)
        }
    }

    public struct Texture: Codable, Equatable, Sendable {
        public var name: String
        public var part: Part
        public init(name: String, part: Part) { (self.name, self.part) = (name, part) }
    }

    public struct Chunk: Codable, Equatable, Sendable {
        public var id: String
        public var bytes: Int
        /// "<group>/<category>": "milk/Dancer", "thumbs/Built-in", "shaders.ios/Fractal", "textures/".
        public var group: String
    }

    public var format = PresetCacheFormat.format
    public var renderer = PresetCacheFormat.renderer
    public var presets: [Entry]
    /// The default shaders' compiled parts: "warp.macos" …
    public var defaults: [String: Part]
    public var textures: [Texture]
    public var chunks: [Chunk]

    public init(presets: [Entry], defaults: [String: Part], textures: [Texture], chunks: [Chunk]) {
        (self.presets, self.defaults, self.textures, self.chunks) = (presets, defaults, textures, chunks)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes to the device per category: `.milk`, picture and this platform's shaders.
    public func bytes(platform: String = PresetCDN.platform) -> [String: Int] {
        let kinds = ["milk", "thumb", "warp.\(platform)", "comp.\(platform)"]
        return presets.reduce(into: [:]) { sum, entry in
            sum[entry.category, default: 0] += kinds.compactMap { entry.parts[$0] }.filter { !defaults.values.contains($0) }.map(\.length).reduce(0, +)
        }
    }
}

/// Packs parts into chunks the same way every time: by group and category, then key, cut at `limit` bytes. Equal
/// parts give equal chunks, so a new set reuses the chunks of the last one where nothing changed.
public enum PresetCachePacker {
    public struct Item: Sendable {
        public var group: String, category: String, key: String
        public var read: @Sendable () throws -> Data
        public init(group: String, category: String, key: String, read: @escaping @Sendable () throws -> Data) {
            (self.group, self.category, self.key, self.read) = (group, category, key, read)
        }
    }

    public static let limit = 32 << 20

    /// A part for each item, in their order, and the chunks; `write(id, bytes)` gets each chunk once.
    public static func pack(_ items: [Item], limit: Int = limit, write: (String, Data) throws -> Void) throws
        -> (parts: [PresetCacheManifest.Part], chunks: [PresetCacheManifest.Chunk]) {
        var parts = [PresetCacheManifest.Part?](repeating: nil, count: items.count)
        var chunks: [PresetCacheManifest.Chunk] = []
        var buffer = Data(), pending: [(index: Int, offset: Int, length: Int, sha256: String)] = [], group = ""
        func flush() throws {
            guard !buffer.isEmpty else { return }
            let id = PresetCacheManifest.sha256(buffer)
            if !chunks.contains(where: { $0.id == id }) {
                try write(id, buffer)
                chunks.append(.init(id: id, bytes: buffer.count, group: group))
            }
            for p in pending { parts[p.index] = .init(chunk: id, offset: p.offset, length: p.length, sha256: p.sha256) }
            buffer = Data()
            pending = []
        }
        let order = items.indices.sorted { (items[$0].group, items[$0].category, items[$0].key) < (items[$1].group, items[$1].category, items[$1].key) }
        for i in order {
            let item = items[i], bucket = item.group + "/" + item.category
            if bucket != group { try flush(); group = bucket }
            let data = try item.read()
            if !buffer.isEmpty, buffer.count + data.count > limit { try flush() }
            pending.append((i, buffer.count, data.count, PresetCacheManifest.sha256(data)))
            buffer.append(data)
        }
        try flush()
        return (parts.map { $0! }, chunks)
    }
}
