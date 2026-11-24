import Foundation
import MilkDropKit

/// Makes the preset cache (`PresetCDN`): compiles, renders and measures every bundled and Cream of the Crop preset,
/// compiles its shaders for macOS and iOS, packs it all into chunks and uploads what R2 does not have yet.
/// Results are kept by `.milk` hash in a work folder, so a second run only packs. See `scripts/preset-cache.sh`.
@main struct PresetCacheTool {
    struct Options: Sendable {
        var sample: Int?
        var dryRun = false, refresh = false
        var platforms = ["macos", "ios"]
        var prefix = "milkdrop"
    }

    struct Source: Sendable {
        var pack, category, name: String
        var url: URL
    }

    /// What a pack item is.
    enum Ref { case preset(Int, String), defaults(String), texture(String) }

    static let stages: [ShaderStage] = [.warp, .comp]

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)  // progress shows in a log file as it happens
        do { try await run(options()) } catch {
            report("error: \(error)")
            exit(1)
        }
    }

    static func options() throws -> Options {
        var options = Options()
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--sample": options.sample = arguments.next().flatMap { Int($0) }
            case "--dry-run": options.dryRun = true
            case "--refresh": options.refresh = true
            case "--platforms": options.platforms = (arguments.next() ?? "").split(separator: ",").map(String.init).filter { $0 != "none" }
            case "--prefix": options.prefix = arguments.next() ?? options.prefix
            default: throw ToolError("unknown option \(argument); use --sample N, --dry-run, --refresh, --platforms macos,ios, --prefix P")
            }
        }
        return options
    }

    static func run(_ options: Options) async throws {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MusicSync/PresetCacheTool")
        let work = root.appendingPathComponent("r\(PresetCacheFormat.renderer)")
        let out = root.appendingPathComponent("out/\(options.prefix)")
        let chunks = out.appendingPathComponent("chunks")
        try fm.createDirectory(at: chunks, withIntermediateDirectories: true)

        if !options.platforms.isEmpty, Shell.run("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"]).code != 0 {
            throw ToolError("the Metal Toolchain is missing; install it with `xcodebuild -downloadComponent MetalToolchain`, or pass --platforms none")
        }
        var list = try await sources(root)
        if let n = options.sample, n < list.count {
            let step = Double(list.count) / Double(n)
            list = (0..<n).map { list[Int(Double($0) * step)] }
        }
        let files = try list.map { try Data(contentsOf: $0.url) }
        let hashes = files.map(PresetCacheManifest.sha256)
        var unique: [String: URL] = [:]
        for (source, hash) in zip(list, hashes) where unique[hash] == nil { unique[hash] = source.url }
        report("\(list.count) presets, \(unique.count) different files; platforms \(options.platforms.joined(separator: ","))")

        // Compute what the work folder does not have.
        guard let baker = PresetBaker() else { throw ToolError("no Metal device") }
        let started = Date()
        var baked = 0, compiled = 0, finished = 0
        let width = max(ProcessInfo.processInfo.activeProcessorCount / 2, 2)
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            var next = unique.sorted { $0.key < $1.key }.makeIterator()
            func add() -> Bool {
                guard let (hash, url) = next.next() else { return false }
                group.addTask { try await prepare(url, in: work.appendingPathComponent(hash), baker: baker, options: options) }
                return true
            }
            for _ in 0..<width where add() {}
            for try await (b, c) in group {
                (baked, compiled, finished) = (baked + b, compiled + c, finished + 1)
                if finished % 100 == 0 {
                    let s = Date().timeIntervalSince(started), left = s / Double(finished) * Double(unique.count - finished)
                    let line = "  \(finished) of \(unique.count) (\(finished * 100 / unique.count)%), \(baked) computed, \(Int(s / 60)) min, about \(Int(left / 60)) min left"
                    if finished % 500 == 0 { report(line) } else { print(line) }
                }
                _ = add()
            }
        }
        let defaults = work.appendingPathComponent("default")
        try fm.createDirectory(at: defaults, withIntermediateDirectories: true)
        for platform in options.platforms {
            for stage in stages {
                let lib = defaults.appendingPathComponent("\(stage).\(platform).metallib")
                if options.refresh || !fm.fileExists(atPath: lib.path) {
                    guard Shell.metallib(HLSLTranslator.defaultShader(stage).source, platform: platform, to: lib) else { throw ToolError("default \(stage) shader does not compile") }
                    compiled += 1
                }
            }
        }
        let seconds = Date().timeIntervalSince(started)
        report(String(format: "Computed %d presets and %d shader libraries in %.0f s (%.2f s a preset); %d from the work folder",
                     baked, compiled, seconds, baked > 0 ? seconds / Double(baked) : 0, unique.count - baked))

        // Pack.
        var items: [PresetCachePacker.Item] = [], refs: [Ref] = []
        func add(_ ref: Ref, _ group: String, _ category: String, _ key: String, _ url: URL) {
            refs.append(ref)
            items.append(.init(group: group, category: category, key: key) { try Data(contentsOf: url) })
        }
        let results = try hashes.map { try JSONDecoder().decode(PresetBaker.Result.self, from: Data(contentsOf: work.appendingPathComponent("\($0)/status.json"))) }
        for (i, source) in list.enumerated() {
            let dir = work.appendingPathComponent(hashes[i])
            add(.preset(i, "milk"), "milk", source.category, source.name, source.url)
            guard results[i].status.ok else { continue }
            add(.preset(i, "thumb"), "thumbs", source.category, source.name, dir.appendingPathComponent("thumb.jpg"))
            for platform in options.platforms {
                for stage in stages where fm.fileExists(atPath: dir.appendingPathComponent("\(stage).\(platform).metallib").path) {
                    add(.preset(i, "\(stage).\(platform)"), "shaders.\(platform)", source.category, "\(source.name)/\(stage)",
                        dir.appendingPathComponent("\(stage).\(platform).metallib"))
                }
            }
        }
        for platform in options.platforms {
            for stage in stages {
                add(.defaults("\(stage).\(platform)"), "shaders.\(platform)", "Default", "\(stage)", defaults.appendingPathComponent("\(stage).\(platform).metallib"))
            }
        }
        for url in try fm.contentsOfDirectory(at: MilkDropResources.textures!, includingPropertiesForKeys: nil) {
            add(.texture(url.lastPathComponent), "textures", "", url.lastPathComponent, url)
        }
        let packed = try PresetCachePacker.pack(items) { id, data in
            let file = chunks.appendingPathComponent("\(id).bin")
            if !fm.fileExists(atPath: file.path) { try data.write(to: file) }
        }
        var parts = [[String: PresetCacheManifest.Part]](repeating: [:], count: list.count)
        var defaultParts: [String: PresetCacheManifest.Part] = [:], textures: [PresetCacheManifest.Texture] = []
        var sizes: [String: (count: Int, bytes: Int)] = [:]
        for (ref, part) in zip(refs, packed.parts) {
            switch ref {
            case let .preset(i, kind): parts[i][kind] = part; sizes[kind, default: (0, 0)].count += 1; sizes[kind]!.bytes += part.length
            case let .defaults(kind): defaultParts[kind] = part; sizes["default." + kind] = (1, part.length)
            case let .texture(name): textures.append(.init(name: name, part: part)); sizes["texture", default: (0, 0)].count += 1; sizes["texture"]!.bytes += part.length
            }
        }
        let entries = list.enumerated().map { i, source in
            var own = parts[i]
            let dir = work.appendingPathComponent(hashes[i])
            for platform in options.platforms where results[i].status.ok {
                for stage in stages where fm.fileExists(atPath: dir.appendingPathComponent("\(stage).default").path) {
                    own["\(stage).\(platform)"] = defaultParts["\(stage).\(platform)"]
                }
            }
            let preset = try? PresetFile.load(source.url)
            let shaders = Dictionary(uniqueKeysWithValues: zip(stages, [preset?.warp, preset?.comp]).compactMap { stage, hlsl -> (String, ShaderInfo)? in
                guard own.contains(where: { $0.key.hasPrefix("\(stage).") && $0.value != defaultParts[$0.key] }), let hlsl, let shader = try? HLSLTranslator.translate(hlsl, stage: stage) else { return nil }
                return ("\(stage)", shader.info)
            })
            let mtime = ((try? fm.attributesOfItem(atPath: source.url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970.rounded(.down) ?? 0
            return PresetCacheManifest.Entry(name: source.name, pack: source.pack, category: source.category, sha256: hashes[i], size: files[i].count,
                                             mtime: mtime, status: results[i].status, look: results[i].look, flash: results[i].flash, parts: own,
                                             shaders: shaders.isEmpty ? nil : shaders)
        }
        let manifest = PresetCacheManifest(presets: entries, defaults: defaultParts, textures: textures, chunks: packed.chunks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(manifest)
        let manifestFile = out.appendingPathComponent("manifest.json")
        try json.write(to: manifestFile)
        guard Shell.run("/usr/bin/gzip", ["-9", "-n", "-k", "-f", manifestFile.path]).code == 0 else { throw ToolError("gzip failed") }
        let gzipped = manifestFile.appendingPathExtension("gz")
        let hash = PresetCacheManifest.sha256(json).prefix(8)
        for file in try fm.contentsOfDirectory(atPath: chunks.path) where !packed.chunks.contains(where: { "\($0.id).bin" == file }) {
            try fm.removeItem(at: chunks.appendingPathComponent(file))
        }

        let total = packed.chunks.map(\.bytes).reduce(0, +)
        print("Parts:")
        for (kind, size) in sizes.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(size.count), \(size.bytes) bytes") }
        print("Chunks: \(packed.chunks.count), \(total) bytes; manifest \(json.count) bytes, \((try? Data(contentsOf: gzipped).count) ?? 0) gzipped")
        for group in Set(packed.chunks.map { $0.group.split(separator: "/").first.map(String.init) ?? "" }).sorted() {
            let mine = packed.chunks.filter { $0.group.hasPrefix(group + "/") }
            print("  \(group): \(mine.count) chunks, \(mine.map(\.bytes).reduce(0, +)) bytes")
        }
        guard !options.dryRun else { report("Dry run: nothing uploaded"); return }

        // Upload: chunks R2 lacks, then the manifest, then the index, which makes the set visible.
        guard var storage = Storage(prefix: options.prefix) else { throw ToolError("S3_BUCKET is not set; is ENV_FILE right?") }
        let keys = try storage.list()
        let missing = packed.chunks.filter { !keys.contains("chunks/\($0.id).bin") }
        if !missing.isEmpty {
            report("Uploading \(missing.count) of \(packed.chunks.count) chunks, \(missing.map(\.bytes).reduce(0, +) / 1_000_000) MB…")
            try storage.upload(chunks, files: missing.map { "\($0.id).bin" }, to: "chunks", type: "application/octet-stream", cache: "public, max-age=31536000, immutable")
        }
        let existing = keys.first { $0.hasPrefix("datasets/r\(PresetCacheFormat.renderer)-") && $0.hasSuffix("-\(hash)/manifest.json.gz") }
        let day = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        let id = existing.map { String($0.dropFirst("datasets/".count).dropLast("/manifest.json.gz".count)) } ?? "r\(PresetCacheFormat.renderer)-\(day)-\(hash)"
        if existing == nil {
            try storage.upload(gzipped, to: "datasets/\(id)/manifest.json.gz", type: "application/gzip", cache: "public, max-age=31536000, immutable")
        }
        var index = keys.contains("index.json") ? try JSONDecoder().decode(PresetCacheIndex.self, from: storage.read("index.json")) : PresetCacheIndex()
        let renderer = String(PresetCacheFormat.renderer)
        var indexUploaded = false
        if index.latest[renderer] != id || !index.datasets.contains(where: { $0.id == id }) {
            if !index.datasets.contains(where: { $0.id == id }) {
                index.datasets.append(.init(id: id, renderer: PresetCacheFormat.renderer, created: Date.now.formatted(.iso8601),
                                            manifest: "datasets/\(id)/manifest.json.gz", presets: entries.count, bytes: total))
            }
            index.latest[renderer] = id
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            let file = out.appendingPathComponent("index.json")
            try encoder.encode(index).write(to: file)
            try storage.upload(file, to: "index.json", type: "application/json", cache: "max-age=300")
            indexUploaded = true
        }
        report("Uploaded \(missing.count) of \(packed.chunks.count) chunks (\(missing.map(\.bytes).reduce(0, +)) bytes), manifest \(existing == nil ? "yes" : "no"), index \(indexUploaded ? "yes" : "no"); \(storage.requests) requests")
        report("Dataset \(id)")
    }

    /// Bundled presets, then the pack's (downloaded once into `root`), by category and name.
    static func sources(_ root: URL) async throws -> [Source] {
        let fm = FileManager.default
        func milk(_ folder: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "milk" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func source(_ pack: String, _ category: String) -> (URL) -> Source {
            { Source(pack: pack, category: category, name: $0.deletingPathExtension().lastPathComponent, url: $0) }
        }
        guard let builtIn = MilkDropResources.presets else { throw ToolError("no bundled presets") }
        var all = milk(builtIn).map(source("builtin", PresetLibrary.builtInCategory))
        let pack = root.appendingPathComponent("pack-\(PresetPack.commit)"), complete = pack.appendingPathComponent(".complete")
        if !fm.fileExists(atPath: complete.path) {
            print("Downloading Cream of the Crop at \(PresetPack.commit.prefix(8))…")
            try? fm.removeItem(at: pack)
            let n = try await PresetPack.download(Set(PresetPack.categories.map(\.name)), to: pack)
            print("  \(n) presets")
            fm.createFile(atPath: complete.path, contents: nil)
        }
        for category in PresetPack.categories { all += milk(pack.appendingPathComponent(category.name)).map(source("cream-of-the-crop", category.name)) }
        return all
    }

    /// Makes what `dir` lacks for the preset file `url`: status, measures and picture (`status.json`, `thumb.jpg`),
    /// then each platform's shader libraries (`warp.macos.metallib`; `warp.default` for a stage on the default
    /// shader, `warp.macos.failed` for one the offline compiler rejects). Returns how many of each it made.
    static func prepare(_ url: URL, in dir: URL, baker: PresetBaker, options: Options) async throws -> (Int, Int) {
        let fm = FileManager.default
        let status = dir.appendingPathComponent("status.json")
        var baked = 0, compiled = 0
        if options.refresh || !fm.fileExists(atPath: status.path) {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let result = await baker.bake(url, thumbnail: dir.appendingPathComponent("thumb.jpg"))
            try JSONEncoder().encode(result).write(to: status)
            baked = 1
        }
        let result = try JSONDecoder().decode(PresetBaker.Result.self, from: Data(contentsOf: status))
        guard result.status.ok else { return (baked, 0) }
        var preset: Preset?
        for stage in stages {
            let none = dir.appendingPathComponent("\(stage).default")
            for platform in options.platforms {
                let lib = dir.appendingPathComponent("\(stage).\(platform).metallib"), failed = dir.appendingPathComponent("\(stage).\(platform).failed")
                guard ![none, lib, failed].contains(where: { fm.fileExists(atPath: $0.path) }) else { continue }
                if preset == nil { preset = try PresetFile.load(url) }
                guard let source = PresetBaker.shader(preset!, stage, fallbacks: result.status.fallbacks) else {
                    fm.createFile(atPath: none.path, contents: nil)
                    break
                }
                if Shell.metallib(source, platform: platform, to: lib) { compiled += 1 } else { fm.createFile(atPath: failed.path, contents: nil) }
            }
        }
        return (baked, compiled)
    }
}

/// Prints `line` and, when `PROGRESS_CMD` is set, runs it with the line (for example a chat notifier).
func report(_ line: String) {
    print(line)
    guard let command = ProcessInfo.processInfo.environment["PROGRESS_CMD"], !command.isEmpty else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command + " \"$0\"", "PresetCacheTool: " + line.trimmingCharacters(in: .whitespaces)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}
