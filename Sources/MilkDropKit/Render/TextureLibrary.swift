import Foundation
import MetalKit

/// Image textures that preset shaders name (`sampler_clouds2` → `clouds2.jpg`), loaded on first use and kept.
/// `rand00`…`rand15`, optionally with a suffix (`rand02_smalltiled`), pick a random image whose name starts with the
/// suffix, as in MilkDrop. A missing image gives `clouds2`, as in butterchurn.
final class TextureLibrary {
    private let loader: MTKTextureLoader
    private let files: [String: URL]
    private var cache: [String: MTLTexture] = [:]
    private let random: () -> Double

    /// Images in `folders`; a later folder wins on equal names.
    init(device: MTLDevice, folders: [URL], random: @escaping () -> Double = { .random(in: 0..<1) }) {
        loader = MTKTextureLoader(device: device)
        self.random = random
        var files: [String: URL] = [:]
        for folder in folders {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where ["jpg", "jpeg", "png", "tga", "bmp", "dds"].contains(url.pathExtension.lowercased()) {
                files[url.deletingPathExtension().lastPathComponent.lowercased()] = url
            }
        }
        self.files = files
    }

    /// Texture for a sampler name without its `sampler_` and filter prefixes. Random picks stay fixed per name until
    /// `reshuffle`, so one preset samples the same image all along.
    func texture(_ name: String) -> MTLTexture? {
        let key = name.lowercased()
        if let t = cache[key] { return t }
        let file = Self.randomSuffix(key).map(pick) ?? files[key] ?? files["clouds2"]
        guard let file, let t = try? loader.newTexture(URL: file, options: [
            .SRGB: false, .generateMipmaps: true, .origin: MTKTextureLoader.Origin.topLeft, .textureStorageMode: MTLStorageMode.private.rawValue,
        ]) else { return nil }
        cache[key] = t
        return t
    }

    /// New random images for the `randNN` names (a new preset).
    func reshuffle() { cache = cache.filter { Self.randomSuffix($0.key) == nil } }

    /// For `rand05_smalltiled` the suffix `smalltiled`, for `rand05` an empty one; nil for other names.
    static func randomSuffix(_ name: String) -> String? {
        guard name.hasPrefix("rand"), name.count >= 6, name.dropFirst(4).prefix(2).allSatisfy(\.isNumber) else { return nil }
        let rest = name.dropFirst(6)
        if rest.isEmpty { return "" }
        return rest.first == "_" ? String(rest.dropFirst()) : nil
    }

    private func pick(_ suffix: String) -> URL? {
        let names = files.keys.filter { suffix.isEmpty || $0.hasPrefix(suffix) }.sorted()
        guard !names.isEmpty else { return nil }
        return files[names[min(Int(random() * Double(names.count)), names.count - 1)]]
    }
}
