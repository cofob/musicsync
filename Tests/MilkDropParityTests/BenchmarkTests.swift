import Darwin
import Foundation
import Metal
@testable import MilkDropKit
import Testing

/// Speed and memory of the native renderer against butterchurn in a web view, on the same presets and input.
/// Only presets both render count. Runs only with `MILKDROP_BENCH=1`; prints a table and writes it to
/// `$TMPDIR/MilkDropBench.txt`. Build with `-c release -Xswiftc -enable-testing` for real numbers.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MILKDROP_BENCH"] == "1"))
struct BenchmarkTests {
    static let (width, height, frames) = (1280, 720, 300)

    @Test func nativeAgainstButterchurn() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let folder = try #require(MilkDropResources.presets)
        let all = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
        let files = stride(from: 0, to: all.count, by: 9).map { all[$0] }
        let webBefore = Set(Self.webKitProcesses())

        // butterchurn first: which presets it renders, and its numbers.
        var t = Date()
        let reference = Butterchurn()
        try await reference.load()
        try await reference.setImages(try #require(MilkDropResources.textures))
        let pageLoad = Date().timeIntervalSince(t) * 1000
        let web = Self.webKitProcesses().filter { !webBefore.contains($0) }
        let webCPU0 = web.map(Self.cpuSeconds).reduce(0, +)
        // Presets butterchurn renders right, and those it at least compiles (its converter garbles many shaders).
        var webRows: [String: [String: Double]] = [:], compiled: [String: [String: Double]] = [:]
        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            let milk = ParityTests.referenceMilk(text, try PresetFile.load(file))
            guard let r = try? await reference.bench(milk, width: Self.width, height: Self.height, frames: Self.frames) else { continue }
            if !r.failure.contains("cannot link") { compiled[file.path] = r.times }
            if r.failure.isEmpty { webRows[file.path] = r.times }
        }
        let webCPU = web.map(Self.cpuSeconds).reduce(0, +) - webCPU0
        let webFrames = Double(compiled.count * Self.frames)
        let webMemory = web.map(Self.footprint).reduce(0, +)
        let shared = files.filter { webRows[$0.path] != nil }
        // Compile costs: presets with their own shaders that both compile.
        var coldNative: [Double] = []
        let shaderFiles = try files.filter { compiled[$0.path] != nil }.filter { let p = try PresetFile.load($0); return !p.warp.isEmpty || !p.comp.isEmpty }

        // Native, on the presets butterchurn renders.
        let queue = try #require(device.makeCommandQueue())
        queue.makeCommandBuffer().map { $0.commit(); $0.waitUntilCompleted() }
        let baseMemory = Self.footprint()
        t = Date()
        let renderer = try #require(Renderer(device: device, random: { 0.5 }))
        let nativeCreate = Date().timeIntervalSince(t) * 1000
        let rendererMemory = Self.footprint() - baseMemory
        let screen = try #require(Self.screen(device))
        var parse: [Double] = [], warm: [Double] = [], show: [Double] = [], encode: [Double] = [], mean: [Double] = []
        var cpu = 0.0
        for file in shaderFiles {
            let t = Date()
            try await Self.compileCold(PresetFile.load(file), device: device)
            coldNative.append(Date().timeIntervalSince(t) * 1000)
        }
        for file in shared {
            t = Date()
            let preset = try PresetFile.load(file)
            parse.append(Date().timeIntervalSince(t) * 1000)
            t = Date()
            let compiled = try await CompiledPreset.compile(preset, device: device, screenFormat: .bgra8Unorm)
            warm.append(Date().timeIntervalSince(t) * 1000)
            t = Date()
            try renderer.show(compiled, blend: 0)
            Self.frame(renderer, screen, 0, wait: true)
            show.append(Date().timeIntervalSince(t) * 1000)
            let cpu0 = Self.cpuSeconds()
            t = Date()
            for f in 1...Self.frames { encode.append(Self.frame(renderer, screen, f, wait: f == Self.frames)) }
            mean.append(Date().timeIntervalSince(t) * 1000 / Double(Self.frames))
            cpu += Self.cpuSeconds() - cpu0
        }
        let nativeMemory = Self.footprint() - baseMemory
        let n = Double(shared.count * Self.frames)
        let w = { (key: String) in shared.compactMap { webRows[$0.path]?[key] } }
        let wShaded = { (key: String) in shaderFiles.compactMap { compiled[$0.path]?[key] } }

        let rows = [
            "\(shared.count) presets both render right (of \(files.count)); compile costs from \(shaderFiles.count) presets with own shaders both compile; \(Self.width)×\(Self.height), \(Self.frames) frames each",
            "",
            "                                          median     p95  (ms)",
            row("native: renderer made", [nativeCreate]),
            row("native: parse .milk", parse),
            row("native: translate + compile, new to GPU *", coldNative),
            row("native: translate + compile, cached", warm),
            row("native: show + first frame", show),
            row("native: frame, CPU encode", encode),
            row("native: frame, mean (GPU pipelined)", mean),
            "native: CPU per frame (whole process)          \(String(format: "%7.2f", cpu / n * 1000))",
            "native: memory of the renderer, made           \(String(format: "%7.0f", rendererMemory)) MB",
            "native: memory of the renderer, after all      \(String(format: "%7.0f", nativeMemory)) MB",
            "",
            row("butterchurn: page and scripts loaded", [pageLoad]),
            row("butterchurn: visualizer made", Array(w("create").prefix(1))),
            row("butterchurn: convert .milk (imports)", w("convert")),
            row("butterchurn: load + first frame, new to GPU *", wShaded("cold")),
            row("butterchurn: load + first frame, cached", w("warm")),
            row("butterchurn: frame, mean (GPU pipelined)", w("mean")),
            "butterchurn: CPU per frame (\(web.count) WebKit processes)  \(String(format: "%7.2f", webCPU / max(webFrames, 1) * 1000))",
            "butterchurn: memory of WebKit processes        \(String(format: "%7.0f", webMemory)) MB",
            "",
            "* presets with their own shaders; the others compile nothing new",
        ]
        let text = rows.joined(separator: "\n")
        print(text)
        try text.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("MilkDropBench.txt"), atomically: true, encoding: .utf8)
    }

    private func row(_ name: String, _ values: [Double]) -> String {
        let s = values.sorted()
        guard !s.isEmpty else { return name }
        let p = { (q: Double) in s[min(Int(Double(s.count) * q), s.count - 1)] }
        return name.padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%8.2f %8.2f", p(0.5), p(0.95))
    }

    /// Translates and compiles both shaders at once, as `CompiledPreset` does, the preset's own with a unique comment
    /// added, so Metal's shader cache (keyed by source text) cannot help: what a preset costs the first time it shows.
    static func compileCold(_ preset: Preset, device: MTLDevice) async throws {
        async let warp: Void = compile(preset.warp, .warp, device)
        async let comp: Void = compile(preset.comp, .comp, device)
        _ = try await (warp, comp)
    }

    private static func compile(_ hlsl: String, _ stage: ShaderStage, _ device: MTLDevice) async throws {
        let shader = try hlsl.isEmpty ? HLSLTranslator.defaultShader(stage) : HLSLTranslator.translate(hlsl, stage: stage)
        let library = try await device.makeLibrary(source: shader.source + (hlsl.isEmpty ? "" : "\n// \(UUID())\n"), options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "md_vertex")
        d.fragmentFunction = library.makeFunction(name: "md_fragment")
        d.colorAttachments[0].pixelFormat = stage == .warp ? Targets.format : .bgra8Unorm
        _ = try await device.makeRenderPipelineState(descriptor: d)
    }

    static func screen(_ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// Encodes and commits one frame; returns the CPU time to encode it in ms. `wait`: until the GPU is done.
    @discardableResult
    static func frame(_ renderer: Renderer, _ screen: MTLTexture, _ f: Int, wait: Bool) -> Double {
        let t = Date()
        let buffer = renderer.queue.makeCommandBuffer()!
        let a = ParityTests.audio(f)
        renderer.render(into: screen, buffer: buffer, size: SIMD2(width, height), left: a, right: a, sampleRate: 44100, now: Double(f) / 60)
        buffer.commit()
        let encode = Date().timeIntervalSince(t) * 1000
        if wait { buffer.waitUntilCompleted() }
        return encode
    }

    /// User + system CPU seconds of this process.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Physical footprint of this process in MB (what Activity Monitor shows as memory; GPU memory included).
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// PIDs of WebKit's helper processes (web content, GPU, networking).
    static func webKitProcesses() -> [Int32] {
        shell("/bin/ps", ["-axo", "pid=,comm="]).split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            return parts.count == 2 && parts[1].contains("com.apple.WebKit") ? Int32(parts[0]) : nil
        }
    }

    static func cpuSeconds(_ pid: Int32) -> Double {
        let parts = shell("/bin/ps", ["-o", "time=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    /// Physical footprint of another process in MB, from `footprint`.
    static func footprint(_ pid: Int32) -> Double {
        let out = shell("/usr/bin/footprint", ["-p", "\(pid)"])
        guard let line = out.split(separator: "\n").first(where: { $0.contains("Footprint:") }) else { return 0 }
        let parts = line.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(of: "Footprint:"), i + 2 < parts.count, let v = Double(parts[i + 1]) else { return 0 }
        return parts[i + 2].hasPrefix("GB") ? v * 1024 : parts[i + 2].hasPrefix("KB") ? v / 1024 : v
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
