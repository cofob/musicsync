import Foundation
import Metal
@testable import MilkDropKit
import Testing

/// The visualizer test suite: renders presets of every pack with MilkDropKit, butterchurn and projectM from the same
/// input (`ParityTests.audio`, 1/60 s steps, random 0.5) and writes an HTML report that compares them (`SuiteReport`).
/// Runs with `MILKDROP_SUITE=<suite.json>`, as `scripts/visualizer-suite.sh` writes it (see `Config`).
/// No pass or fail limits: the report is the result.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MILKDROP_SUITE"] != nil))
struct VisualizerSuiteTests {
    struct Config: Codable, Sendable {
        struct Pack: Codable, Sendable { var name: String, dir: String }
        /// Report folder.
        var out: String
        /// Presets of each category; 0 for all.
        var sample: Int
        /// "worst", "all" or "none".
        var videos: String
        /// The projectM tool of `scripts/projectm-reference.sh`, and the texture folder for all three engines.
        var projectM: String, textures: String
        /// File of the worst presets of the last run (`pack/relative path` lines), which this run takes again.
        var known: String
        var packs: [Pack]
    }

    /// One preset to render.
    struct Item: Sendable {
        var id: String, name: String, pack: String, category: String, relative: String, file: URL, known: Bool
    }

    nonisolated static let frames = ParityTests.frames
    /// Seconds of the videos, at 60 frames a second.
    nonisolated static let videoFrames = 240
    static let worstVideos = 12
    /// Parallel projectM processes and native renderers.
    nonisolated static let lanes = (projectM: max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), native: 2)
    /// Seconds a reference may take on one preset before it counts as failed.
    nonisolated static let timeout = 60.0

    /// Presets of `config`: `sample` of each category (an even spread over a fixed shuffle) and the known worst,
    /// without repeated names.
    static func select(_ config: Config) -> [Item] {
        let known = Set(((try? String(contentsOfFile: config.known, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        var groups: [String: [Item]] = [:], order: [String] = []
        for pack in config.packs {
            let root = URL(fileURLWithPath: pack.dir).standardizedFileURL
            let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension.lowercased() == "milk" }
            for file in files {
                let relative = String(file.standardizedFileURL.path.dropFirst(root.path.count + 1))
                let parts = relative.split(separator: "/")
                let category = parts.count > 1 ? parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "! ")) : pack.name
                let key = "\(pack.name)/\(relative)"
                let item = Item(id: String(format: "%016llx", hash(key)), name: file.deletingPathExtension().lastPathComponent, pack: pack.name,
                                category: category, relative: relative, file: file, known: known.contains(key))
                let group = "\(pack.name)/\(category)"
                if groups[group] == nil { order.append(group) }
                groups[group, default: []].append(item)
            }
        }
        var picked: [Item] = groups.values.flatMap { $0.filter(\.known) }
        for group in order {
            let items = groups[group]!.sorted { hash($0.relative) < hash($1.relative) }
            picked += config.sample > 0 ? Array(items.prefix(config.sample)) : items
        }
        var seen = Set<String>()
        return picked.filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// FNV-1a, for ids and the fixed shuffle.
    nonisolated static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    @Test func suite() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MILKDROP_SUITE"])
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let out = URL(fileURLWithPath: config.out, isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: out.appendingPathComponent("p"))
        try fm.createDirectory(at: out.appendingPathComponent("p"), withIntermediateDirectories: true)
        let items = Self.select(config)
        for item in items { try fm.createDirectory(at: Self.folder(out, item), withIntermediateDirectories: true) }
        let textures = URL(fileURLWithPath: config.textures, isDirectory: true)
        let started = Date()
        print("SUITE \(items.count) presets, \(Self.lanes.projectM) projectM and \(Self.lanes.native) native lanes")

        async let projectM = Self.projectMLane(items, tool: config.projectM, textures: textures, out: out)
        async let native = Self.nativeLane(items, device: device, textures: textures, out: out)
        let butterchurn = try await Self.butterchurnLane(items, textures: textures, out: out)
        let (pm, nat) = await (projectM, native)
        let rendered = Date().timeIntervalSince(started)
        print(String(format: "SUITE rendered in %.0f s", rendered))

        var entries = items.indices.map { Self.entry(items[$0], native: nat[$0], butterchurn: butterchurn[$0], projectM: pm[$0], out: out) }
        let worst = entries.indices.sorted { entries[$0].badness > entries[$1].badness }
        let videos = config.videos == "all" ? Array(entries.indices) : config.videos == "none" ? [] : Array(worst.prefix(Self.worstVideos))
        var reference = try await Self.makeButterchurn(textures)
        for index in videos {
            do {
                try await Self.video(items[index], reference: &reference, device: device, tool: config.projectM, textures: textures, out: out)
                entries[index].video = true
            } catch { print("SUITE no video of \(items[index].name): \(error)") }
        }
        let total = Date().timeIntervalSince(started)
        try SuiteReport.write(entries, to: out, seconds: (rendered, total), sample: config.sample)
        let keep = worst.prefix(25).filter { entries[$0].badness > 0 }.map { "\(items[$0].pack)/\(items[$0].relative)" }
        try keep.joined(separator: "\n").write(toFile: config.known, atomically: true, encoding: .utf8)
        print(String(format: "SUITE done in %.0f s: %@", total, out.appendingPathComponent("index.html").path))
        #expect(!entries.isEmpty)
    }

    nonisolated static func done(_ lane: String, since start: Date) {
        print(String(format: "SUITE %@ lane done in %.0f s", lane, Date().timeIntervalSince(start)))
    }

    nonisolated static func folder(_ out: URL, _ item: Item) -> URL { out.appendingPathComponent("p/\(item.id)", isDirectory: true) }

    // MARK: - Native

    struct NativeRun: Sendable {
        var error: String?
        var fallbacks: [String] = [], skipped: [String] = []
        var translateMs: Double?, compileMs: Double?, frameMs: Double?
        /// MSL (or the translator's error) of warp and comp, and the HLSL.
        var msl: [String: String] = [:], hlsl: [String: String] = [:]
        var measure: PresetMeasure?
    }

    /// Every equation block that does not compile, as MilkDrop leaves it out: "per_frame: error".
    nonisolated static func skippedBlocks(_ preset: Preset) -> [String] {
        var blocks = [("init", preset.initCode), ("per_frame", preset.frameCode), ("per_pixel", preset.pixelCode)]
        for (i, w) in preset.waves.enumerated() where w.isEnabled {
            blocks += [("wave\(i)_init", w.initCode), ("wave\(i)_per_frame", w.frameCode), ("wave\(i)_per_point", w.pointCode)]
        }
        for (i, s) in preset.shapes.enumerated() where s.isEnabled { blocks += [("shape\(i)_init", s.initCode), ("shape\(i)_per_frame", s.frameCode)] }
        return blocks.compactMap { name, code in
            do { _ = try EELScope(memory: EELMemory(), globals: EELGlobals()).compile(code); return nil } catch { return "\(name): \(error)" }
        }
    }

    nonisolated static func native(_ item: Item, device: MTLDevice, textures: URL, out: URL) async -> NativeRun {
        var result = NativeRun()
        do {
            let preset = try PresetFile.load(item.file)
            result.skipped = skippedBlocks(preset)
            result.hlsl = ["warp": preset.warp, "comp": preset.comp]
            var start = Date()
            for (name, hlsl, stage) in [("warp", preset.warp, ShaderStage.warp), ("comp", preset.comp, .comp)] where !hlsl.isEmpty {
                do { result.msl[name] = try HLSLTranslator.translate(hlsl, stage: stage).source } catch { result.msl[name] = "translation failed: \(error)" }
            }
            result.translateMs = Date().timeIntervalSince(start) * 1000
            start = Date()
            let compiled = try await CompiledPreset.compile(preset, device: device, screenFormat: MilkDropController.screenFormat)
            result.compileMs = Date().timeIntervalSince(start) * 1000
            result.fallbacks = compiled.fallbacks
            let (frames, ms) = try ParityTests.renderFrames(compiled, device: device, keep: Self.frames, format: MilkDropController.screenFormat, textures: [textures])
            result.frameMs = ms
            for (f, bytes) in frames { ParityTests.savePNG(bytes, to: folder(out, item).appendingPathComponent("native-\(f).png")) }
            result.measure = try? PresetMeasurer.measure(compiled, device: device, noise: nil)
        } catch { result.error = "\(error)" }
        return result
    }

    nonisolated static func nativeLane(_ items: [Item], device: MTLDevice, textures: URL, out: URL) async -> [NativeRun] {
        let start = Date()
        defer { done("native", since: start) }
        return await withTaskGroup(of: [(Int, NativeRun)].self) { group in
            for lane in 0..<lanes.native {
                group.addTask {
                    var done: [(Int, NativeRun)] = []
                    for i in stride(from: lane, to: items.count, by: lanes.native) { done.append((i, await native(items[i], device: device, textures: textures, out: out))) }
                    return done
                }
            }
            var all = [NativeRun](repeating: NativeRun(), count: items.count)
            for await part in group { for (i, n) in part { all[i] = n } }
            return all
        }
    }

    // MARK: - projectM

    struct ProjectMRun: Sendable { var error: String?, log = "" }

    /// Runs the tool for the frames in `keep` into `dir`; nil error when it exits 0. Killed after `timeout`.
    nonisolated static func runProjectM(_ tool: String, _ file: URL, keep: [Int], textures: URL, into dir: URL) async -> ProjectMRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [file.path, dir.path, keep.map(String.init).joined(separator: ","), textures.path]
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("projectm-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        do {
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardError = handle
            process.standardOutput = handle
            let status: Int32 = try await withCheckedThrowingContinuation { done in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { process.terminationHandler = nil; done.resume(throwing: error); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            }
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let reason = process.terminationReason == .uncaughtSignal ? "killed after \(Int(timeout)) s or crashed (signal \(status))"
                : text.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            return ProjectMRun(error: status == 0 && process.terminationReason == .exit ? nil : reason, log: text)
        } catch { return ProjectMRun(error: "\(error)") }
    }

    nonisolated static func projectMLane(_ items: [Item], tool: String, textures: URL, out: URL) async -> [ProjectMRun] {
        let start = Date()
        defer { done("projectM", since: start) }
        return await withTaskGroup(of: [(Int, ProjectMRun)].self) { group in
            for lane in 0..<lanes.projectM {
                group.addTask {
                    var done: [(Int, ProjectMRun)] = []
                    for i in stride(from: lane, to: items.count, by: lanes.projectM) {
                        let dir = folder(out, items[i]).appendingPathComponent("projectm", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        done.append((i, await runProjectM(tool, items[i].file, keep: frames, textures: textures, into: dir)))
                    }
                    return done
                }
            }
            var all = [ProjectMRun](repeating: ProjectMRun(), count: items.count)
            for await part in group { for (i, r) in part { all[i] = r } }
            return all
        }
    }

    // MARK: - butterchurn

    struct ButterchurnRun: Sendable {
        /// Thrown: butterchurn rendered nothing. `failure`: what reference.html saw it get wrong.
        var error: String?, failure: String?
        var notes: [String: String] = [:]
    }

    /// `operation`, or a timeout error after `seconds`; the operation itself goes on, as a web view call cannot stop.
    @MainActor final class Once { var done = false }

    static func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
            let once = Once()
            Task { @MainActor in
                do {
                    let value = try await operation()
                    if !once.done { once.done = true; done.resume(returning: value) }
                } catch { if !once.done { once.done = true; done.resume(throwing: error) } }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if !once.done { once.done = true; done.resume(throwing: ParityError("no answer in \(Int(seconds)) s")) }
            }
        }
    }

    static func makeButterchurn(_ textures: URL) async throws -> Butterchurn {
        let reference = Butterchurn()
        try await reference.load()
        try await reference.setImages(textures)
        return reference
    }

    /// Frames of `keep` and what the reference noted; `reference` is replaced by a new one after a timeout.
    static func butterchurn(_ item: Item, reference: inout Butterchurn, textures: URL, keep: [Int]) async
        -> (frames: [Int: [UInt8]], result: ButterchurnRun) {
        do {
            let preset = try PresetFile.load(item.file)
            let milk = ParityTests.referenceMilk(String(decoding: try Data(contentsOf: item.file), as: UTF8.self), preset)
            let ref = reference
            let frames = try await withTimeout(timeout) { try await ref.render(milk, width: ParityTests.size.w, height: ParityTests.size.h, frames: keep.max()!, keep: keep) }
            return (frames, ButterchurnRun(failure: ref.failure, notes: ref.notes))
        } catch {
            if "\(error)".contains("no answer"), let fresh = try? await makeButterchurn(textures) { reference = fresh }
            return ([:], ButterchurnRun(error: ParityTests.reason(error)))
        }
    }

    static func butterchurnLane(_ items: [Item], textures: URL, out: URL) async throws -> [ButterchurnRun] {
        let start = Date()
        defer { done("butterchurn", since: start) }
        var reference = try await makeButterchurn(textures)
        var all: [ButterchurnRun] = []
        for item in items {
            let (frames, result) = await butterchurn(item, reference: &reference, textures: textures, keep: Self.frames)
            for (f, bytes) in frames { ParityTests.savePNG(bytes, to: folder(out, item).appendingPathComponent("butterchurn-\(f).png")) }
            all.append(result)
        }
        return all
    }

    // MARK: - Scores

    /// Blurred difference 0…255 and luminance correlation (`ProjectMParityTests.score`).
    struct Pair: Codable, Sendable {
        var difference: Double, correlation: Double
        /// Large when the pictures differ in both ways; the ranking and the "disagree" rule use it.
        var badness: Double { difference * (1 - correlation) }
        static let disagree = 25.0
    }

    /// One row of the report.
    struct Entry: Codable, Sendable {
        var id: String, name: String, pack: String, category: String, relative: String, known: Bool
        var status: String
        var nativeError: String?
        var fallbacks: [String], skipped: [String]
        var translateMs: Double?, compileMs: Double?, frameMs: Double?
        /// Per frame of `frames`; nil where a side has no picture.
        var butterchurn: [Pair?], projectM: [Pair?], references: [Pair?]
        /// Why a reference does not count: butterchurn's detected failure or error, projectM's load error.
        var butterchurnFailure: String?, projectMFailure: String?
        var flash: FlashReport?
        var mood: [Double]?
        var video = false
        var debug: [String: String]

        nonisolated static func worst(_ pairs: [Pair?]) -> Double { pairs.compactMap { $0?.badness }.max() ?? 0 }
        /// Worst frame against butterchurn (the engine MilkDropKit follows), or against projectM when butterchurn
        /// does not count; 0 when neither counts.
        var badness: Double {
            butterchurnFailure == nil ? Self.worst(butterchurn) : projectMFailure == nil ? Self.worst(projectM) : 0
        }
        /// Every pair of engines disagrees in some frame (references that failed included).
        var allDisagree: Bool { [butterchurn, projectM, references].allSatisfy { Self.worst($0) > Pair.disagree } }
    }

    static func load(_ url: URL) -> [UInt8]? { ProjectMParityTests.loadPNG(url, width: ParityTests.size.w, height: ParityTests.size.h) }

    static func entry(_ item: Item, native: NativeRun, butterchurn: ButterchurnRun, projectM: ProjectMRun, out: URL) -> Entry {
        let dir = folder(out, item)
        let (w, h) = (ParityTests.size.w, ParityTests.size.h)
        var pairs: [[Pair?]] = [[], [], []]
        for f in frames {
            let n = load(dir.appendingPathComponent("native-\(f).png")), b = load(dir.appendingPathComponent("butterchurn-\(f).png"))
            let p = load(dir.appendingPathComponent("projectm/\(f).png"))
            for (k, (x, y)) in [(n, b), (n, p), (b, p)].enumerated() {
                pairs[k].append(x.flatMap { x in y.map { y in
                    let s = ProjectMParityTests.score(y, x, width: w, height: h)
                    return Pair(difference: s.difference, correlation: s.correlation)
                } })
            }
            for (name, other) in [("butterchurn", b), ("projectm", p)] {
                if let n, let other { SuiteVideo.saveDifference(n, other, to: dir.appendingPathComponent("diff-\(name)-\(f).png")) }
            }
        }
        let status = native.error != nil ? "failed"
            : [native.fallbacks.isEmpty ? nil : "shader fallback", native.skipped.isEmpty ? nil : "EEL skipped"].compactMap { $0 }.joined(separator: " + ")
        var debug: [String: String] = [
            "milk": (try? String(contentsOf: item.file, encoding: .utf8)) ?? String(decoding: (try? Data(contentsOf: item.file)) ?? Data(), as: UTF8.self),
            "projectM log": projectM.log,
        ]
        for (k, v) in native.msl { debug["MSL \(k)"] = v }
        for (k, v) in native.hlsl where !v.isEmpty { debug["HLSL \(k)"] = v }
        for (k, v) in butterchurn.notes where !v.isEmpty { debug["butterchurn \(k)"] = v }
        return Entry(id: item.id, name: item.name, pack: item.pack, category: item.category, relative: item.relative, known: item.known,
                     status: status.isEmpty ? "compiled" : status, nativeError: native.error, fallbacks: native.fallbacks, skipped: native.skipped,
                     translateMs: native.translateMs, compileMs: native.compileMs, frameMs: native.frameMs,
                     butterchurn: pairs[0], projectM: pairs[1], references: pairs[2],
                     butterchurnFailure: butterchurn.error.map { "cannot render: \($0)" } ?? butterchurn.failure,
                     projectMFailure: projectM.error,
                     flash: native.measure?.flash, mood: native.measure.map { [$0.mood.arousal, $0.mood.valence, $0.mood.tension] },
                     debug: debug)
    }

    // MARK: - Video

    /// Renders `videoFrames` frames with each engine and writes `video.mp4`: native, butterchurn, projectM side by side.
    static func video(_ item: Item, reference: inout Butterchurn, device: MTLDevice, tool: String, textures: URL, out: URL) async throws {
        let keep = Array(1...videoFrames)
        let dir = folder(out, item)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("suite-video-\(item.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        async let pm = runProjectM(tool, item.file, keep: keep, textures: textures, into: tmp)
        async let native: [Int: [UInt8]] = Task.detached {
            let compiled = try await CompiledPreset.compile(try PresetFile.load(item.file), device: device, screenFormat: .rgba8Unorm)
            return try ParityTests.renderFrames(compiled, device: device, keep: keep, textures: [textures]).frames
        }.value
        let theirs = await butterchurn(item, reference: &reference, textures: textures, keep: keep).frames
        _ = await pm
        let ours = (try? await native) ?? [:]
        try await SuiteVideo.write(to: dir.appendingPathComponent("video.mp4"), frames: videoFrames) { f in
            [ours[f], theirs[f], load(tmp.appendingPathComponent("\(f).png"))]
        }
    }
}
