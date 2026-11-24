import Foundation
import Metal
@testable import MilkDropKit
import Testing

/// Serves files of a fake preset cache by path and counts the requests.
final class PresetCacheStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.requests.append(path)
        let body = Self.files[path]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct PresetCacheTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let measure = PresetMeasure(
        look: PresetLook(brightness: 0.4, saturation: 0.5, warmth: 0.2, contrast: 0.1, motion: 0.02, beatReaction: 0.3),
        flash: FlashReport(general: 1, red: 0, screen: 0))

    private static func item(_ group: String, _ category: String, _ key: String, _ data: Data) -> PresetCachePacker.Item {
        .init(group: group, category: category, key: key) { data }
    }

    private static func gzip(_ data: Data, in dir: URL) throws -> Data {
        let file = dir.appendingPathComponent("m.json")
        try data.write(to: file)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-9", "-n", "-f", file.path]
        try gzip.run()
        gzip.waitUntilExit()
        return try Data(contentsOf: file.appendingPathExtension("gz"))
    }

    @Test func packsTheSameWayEveryTime() throws {
        let items = (0..<10).map { i in Self.item(i % 2 == 0 ? "thumbs" : "milk", i < 5 ? "A" : "B", "p\(9 - i)", Data(repeating: UInt8(i), count: 40)) }
            + [Self.item("milk", "A", "big", Data(repeating: 99, count: 250))]
        var written: [String: Data] = [:]
        let packed = try PresetCachePacker.pack(items, limit: 100) { written[$0] = $1 }
        let again = try PresetCachePacker.pack(items.reversed(), limit: 100) { _, _ in }
        #expect(packed.chunks == again.chunks && packed.parts == Array(again.parts.reversed()))
        // A chunk holds one group and category, up to the limit; a bigger part has a chunk of its own.
        #expect(packed.chunks.map(\.group) == ["milk/A", "milk/A", "milk/B", "milk/B", "thumbs/A", "thumbs/A", "thumbs/B"])
        #expect(packed.chunks.map(\.bytes) == [250, 80, 80, 40, 80, 40, 80])
        for chunk in packed.chunks { #expect(written[chunk.id]?.count == chunk.bytes && PresetCacheManifest.sha256(written[chunk.id]!) == chunk.id) }
        for (item, part) in zip(items, packed.parts) {
            let bytes = try #require(written[part.chunk]).subdata(in: part.offset..<part.offset + part.length)
            #expect(try bytes == item.read() && PresetCacheManifest.sha256(bytes) == part.sha256)
        }
    }

    @Test func manifestRoundTrips() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let part = PresetCacheManifest.Part(chunk: "c", offset: 1, length: 2, sha256: "s")
        let manifest = PresetCacheManifest(
            presets: [.init(name: "A", pack: "cream-of-the-crop", category: "Dancer", sha256: "h", size: 3, mtime: 1_700_000_000,
                            status: .init(ok: true, fallbacks: ["comp: line 1"], skipped: ["x"]), look: Self.measure.look,
                            flash: Self.measure.flash, parts: ["milk": part, "warp.macos": part])],
            defaults: ["comp.macos": .init(chunk: "d", offset: 0, length: 5, sha256: "d")], textures: [.init(name: "t.jpg", part: part)],
            chunks: [.init(id: "c", bytes: 3, group: "milk/Dancer")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(manifest)
        #expect(try JSONDecoder().decode(PresetCacheManifest.self, from: TarGzip.gunzip(Self.gzip(json, in: dir))) == manifest)
        #expect(manifest.bytes(platform: "macos") == ["Dancer": 4] && manifest.bytes(platform: "ios") == ["Dancer": 2])
    }

    @Test func installsCategoriesFromTheCache() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = Data("[preset00]\nper_frame_1=zoom = 1.01;\n".utf8), broken = Data("[preset00]\nbroken\n".utf8)
        let (goodHash, brokenHash) = (PresetCacheManifest.sha256(good), PresetCacheManifest.sha256(broken))
        let items = [Self.item("milk", "Dancer", "Good", good), Self.item("milk", "Dancer", "Broken", broken),
                     Self.item("thumbs", "Dancer", "Good", Data("jpeg".utf8)), Self.item("shaders.macos", "Dancer", "Good/warp", Data("warp mac".utf8)),
                     Self.item("shaders.ios", "Dancer", "Good/warp", Data("warp ios".utf8)), Self.item("shaders.macos", "Default", "comp", Data("comp mac".utf8)),
                     Self.item("shaders.ios", "Default", "comp", Data("comp ios".utf8)), Self.item("milk", "Fractal", "Other", Data("[preset00]\n".utf8))]
        var chunks: [String: Data] = [:]
        let packed = try PresetCachePacker.pack(items) { chunks[$0] = $1 }
        let p = packed.parts
        let manifest = PresetCacheManifest(
            presets: [
                .init(name: "Good", pack: "cream-of-the-crop", category: "Dancer", sha256: goodHash, size: good.count, mtime: 1_700_000_000,
                      status: .init(ok: true), look: Self.measure.look, flash: Self.measure.flash,
                      parts: ["milk": p[0], "thumb": p[2], "warp.macos": p[3], "warp.ios": p[4], "comp.macos": p[5], "comp.ios": p[6]]),
                .init(name: "Broken", pack: "cream-of-the-crop", category: "Dancer", sha256: brokenHash, size: broken.count, mtime: 1_600_000_000,
                      status: .init(ok: false, error: "no"), look: nil, flash: nil, parts: ["milk": p[1]]),
                .init(name: "Other", pack: "cream-of-the-crop", category: "Fractal", sha256: "x", size: 11, mtime: 0,
                      status: .init(ok: false), look: nil, flash: nil, parts: ["milk": p[7]]),
            ],
            defaults: ["comp.macos": p[5], "comp.ios": p[6]], textures: [], chunks: packed.chunks)
        var index = PresetCacheIndex()
        index.datasets = [.init(id: "r1-x", renderer: PresetCacheFormat.renderer, created: "now", manifest: "datasets/r1-x/manifest.json.gz", presets: 3, bytes: 0)]
        index.latest = [String(PresetCacheFormat.renderer): "r1-x"]
        PresetCacheStub.files = ["/cache/index.json": try JSONEncoder().encode(index),
                                 "/cache/datasets/r1-x/manifest.json.gz": try Self.gzip(JSONEncoder().encode(manifest), in: dir)]
        for (id, data) in chunks { PresetCacheStub.files["/cache/chunks/\(id).bin"] = data }
        PresetCacheStub.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PresetCacheStub.self]
        let cdn = PresetCDN(base: URL(string: "https://cache.test/cache")!, session: URLSession(configuration: config))
        let places = PresetCDN.Places(downloads: dir.appendingPathComponent("Downloaded"), thumbnails: dir.appendingPathComponent("Thumbs"),
                                      index: dir.appendingPathComponent("compiled.json"), measures: dir.appendingPathComponent("measures.json"),
                                      shaders: dir.appendingPathComponent("Shaders"), builtIn: nil)

        let fetched = try #require(try await cdn.manifest())
        #expect(fetched == manifest)
        #expect(PresetCDN.categories(fetched).map { "\($0.name) \($0.count)" } == ["Dancer 2", "Fractal 1"])
        PresetCacheStub.requests = []
        #expect(try await cdn.install(["Dancer"], from: fetched, into: places) == 2)
        // Each chunk of the category once: milk, thumbs and this platform's shaders (the default one's too).
        let wanted = Set(packed.chunks.filter { ["milk/Dancer", "thumbs/Dancer", "shaders.\(PresetCDN.platform)/Dancer", "shaders.\(PresetCDN.platform)/Default"].contains($0.group) }.map { "/cache/chunks/\($0.id).bin" })
        #expect(PresetCacheStub.requests.count == wanted.count && Set(PresetCacheStub.requests) == wanted)

        let library = PresetLibrary(builtIn: nil, folders: [places.downloads])
        #expect(library.entries.keys.sorted() == ["Broken", "Good"])
        let entry = try #require(library.entries["Good"]), failed = try #require(library.entries["Broken"])
        #expect(try Data(contentsOf: entry.url) == good)
        #expect((try FileManager.default.attributesOfItem(atPath: entry.url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 == 1_700_000_000)
        #expect(CompileIndex.at(places.index).status(entry) == true && CompileIndex.at(places.index).status(failed) == false)
        #expect(PresetMeasures(url: places.measures).measure(entry) == Self.measure)
        #expect(try Data(contentsOf: PresetThumbnails(folder: places.thumbnails).url(entry)) == Data("jpeg".utf8))
        let mac = PresetCDN.platform == "macos"
        #expect(try Data(contentsOf: places.shaders.appendingPathComponent("\(goodHash)-warp.metallib")) == Data((mac ? "warp mac" : "warp ios").utf8))
        #expect(try Data(contentsOf: places.shaders.appendingPathComponent("default-comp.metallib")) == Data((mac ? "comp mac" : "comp ios").utf8))
        #expect(!FileManager.default.fileExists(atPath: places.shaders.appendingPathComponent("\(goodHash)-comp.metallib").path))

        // Installed presets are not fetched again.
        PresetCacheStub.requests = []
        #expect(try await cdn.install(["Dancer"], from: fetched, into: places) == 0)
        #expect(PresetCacheStub.requests.isEmpty)
    }

    /// A shader library from the cache replaces compiling; one that does not load is compiled from source instead.
    @Test func compiledShadersLoadFromTheCache() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("A.milk")
        try Data("[preset00]\nPSVERSION_WARP=2\nwarp_1=`shader_body { ret = tex2D(sampler_main, uv).rgb * 0.9; }\n".utf8).write(to: file)
        let preset = try PresetFile.load(file)
        #expect(preset.sourceHash == PresetCacheManifest.sha256(try Data(contentsOf: file)))
        try Data("not a library".utf8).write(to: dir.appendingPathComponent("\(preset.sourceHash)-warp.metallib"))
        let fromSource = try await CompiledPreset.compile(preset, device: device, screenFormat: .bgra8Unorm, shaders: dir)
        #expect(fromSource.prebuilt == 0 && fromSource.fallbacks.isEmpty)

        // The offline compiler needs Xcode's Metal Toolchain.
        func metallib(_ source: String, _ name: String) throws -> Bool {
            let src = dir.appendingPathComponent("\(name).metal")
            try source.write(to: src, atomically: true, encoding: .utf8)
            let metal = Process()
            metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            metal.arguments = ["-sdk", "macosx", "metal", "-mmacosx-version-min=15.0", "-o", dir.appendingPathComponent("\(name).metallib").path, src.path]
            metal.standardError = FileHandle.nullDevice
            try metal.run()
            metal.waitUntilExit()
            return metal.terminationStatus == 0
        }
        guard try metallib(HLSLTranslator.translate(preset.warp, stage: .warp).source, "\(preset.sourceHash)-warp"),
              try metallib(HLSLTranslator.defaultShader(.comp).source, "default-comp") else { return }
        let prebuilt = try await CompiledPreset.compile(preset, device: device, screenFormat: .bgra8Unorm, shaders: dir)
        #expect(prebuilt.prebuilt == 2 && prebuilt.fallbacks.isEmpty)
        let renderer = try #require(Renderer(device: device))
        try renderer.show(prebuilt, blend: 0)
    }

    /// Against a real cache: `PRESET_CDN_TEST=https://musicsync-cache.cfb.wtf/milkdrop-test swift test --filter PresetCacheTests`.
    @Test func installsFromTheRealCache() async throws {
        guard let base = ProcessInfo.processInfo.environment["PRESET_CDN_TEST"].flatMap(URL.init(string:)),
              let device = MTLCreateSystemDefaultDevice() else { return }
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cdn = PresetCDN(base: base)
        let manifest = try #require(try await cdn.manifest())
        let places = PresetCDN.Places(downloads: dir.appendingPathComponent("Downloaded"), thumbnails: dir.appendingPathComponent("Thumbs"),
                                      index: dir.appendingPathComponent("compiled.json"), measures: dir.appendingPathComponent("measures.json"),
                                      shaders: dir.appendingPathComponent("Shaders"))
        let categories = Set(manifest.presets.map(\.category))
        let start = Date()
        let installed = try await cdn.install(categories, from: manifest, into: places)
        print("Installed \(installed) of \(manifest.presets.count) presets in \(Date().timeIntervalSince(start)) s")
        let library = PresetLibrary(builtIn: MilkDropResources.presets, folders: [places.downloads])
        let index = CompileIndex.at(places.index), measures = PresetMeasures.at(places.measures), thumbnails = PresetThumbnails(folder: places.thumbnails)
        var times: [Double] = [], prebuilt = 0
        for entry in manifest.presets {
            let local = try #require(entry.pack == "builtin" ? library.entries[entry.name]
                                     : PresetLibrary(builtIn: nil, folders: [places.downloads]).entries[entry.name])
            #expect(index.status(local) == entry.status.ok)
            guard entry.status.ok else { continue }
            #expect(measures.measure(local) != nil && thumbnails.cached(local) != nil)
            let t = Date()
            let compiled = try await CompiledPreset.compile(try PresetFile.load(local.url), device: device, screenFormat: .bgra8Unorm, shaders: places.shaders)
            times.append(Date().timeIntervalSince(t))
            prebuilt += compiled.prebuilt
        }
        print("Compiled \(times.count) presets, \(prebuilt) stages from the cache, median \(times.sorted()[times.count / 2] * 1000) ms")
    }
}
