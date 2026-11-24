import Foundation
import ImageIO
import Metal
@testable import MilkDropKit
import Testing
import UniformTypeIdentifiers

/// Renders bundled presets with butterchurn and with MilkDropKit from the same input (audio bytes, 1/60 s steps,
/// every random value 0.5) and compares the pictures. Images of both and a summary go to `report`.
@MainActor @Suite(.serialized) struct ParityTests {
    nonisolated static let size = (w: 256, h: 192)
    nonisolated static let frames = [1, 10, 30]
    /// `MILKDROP_PARITY_REPORT` sets it, so runs at the same time do not share it.
    static let report = ProcessInfo.processInfo.environment["MILKDROP_PARITY_REPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("MilkDropParity", isDirectory: true)
    /// Presets butterchurn gets wrong in ways reference.html cannot see, with why. They do not count for the medians.
    static let knownReferenceFailures: [String: String] = [:]

    /// Mean absolute difference 0…255 of the RGB channels, after both are averaged in 4×4 blocks (small shifts count less).
    static func difference(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> Double {
        var sum = 0.0, count = 0
        for by in stride(from: 0, to: height - 3, by: 4) {
            for bx in stride(from: 0, to: width - 3, by: 4) {
                for c in 0..<3 {
                    var sa = 0, sb = 0
                    for y in by..<by + 4 { for x in bx..<bx + 4 { let i = (y * width + x) * 4 + c; sa += Int(a[i]); sb += Int(b[i]) } }
                    sum += abs(Double(sa - sb)) / 16
                    count += 1
                }
            }
        }
        return sum / Double(max(count, 1))
    }

    /// The test audio of frame `f`, as `audio(f)` in reference.html, as floats that give back the same bytes.
    nonisolated static func audio(_ f: Int) -> [Float] {
        (0..<1024).map { i in
            let b = min(max((128 + 100 * sin(Double(f * 1024 + i) * 0.05)).rounded(.down), 0), 255)
            return Float((b - 128) / 128)
        }
    }

    /// RGBA bytes, rows top first, of the frames in `keep` rendered natively.
    static func native(_ preset: Preset, device: MTLDevice, keep: [Int]) async throws -> [Int: [UInt8]] {
        try renderFrames(try await CompiledPreset.compile(preset, device: device, screenFormat: .rgba8Unorm), device: device, keep: keep).frames
    }

    /// RGBA bytes, rows top first, of the frames in `keep` of a preset compiled for `format` (.rgba8Unorm or
    /// .bgra8Unorm), and the mean ms of a frame after the first (rendering and waiting for the GPU).
    nonisolated static func renderFrames(_ compiled: CompiledPreset, device: MTLDevice, keep: [Int], format: MTLPixelFormat = .rgba8Unorm,
                                   textures: [URL] = []) throws -> (frames: [Int: [UInt8]], ms: Double) {
        let renderer = try #require(Renderer(device: device, textureFolders: textures, random: { 0.5 }))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.w, height: size.h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let screen = try #require(device.makeTexture(descriptor: d))
        try renderer.show(compiled, blend: 0)
        var out: [Int: [UInt8]] = [:], time = 0.0
        for f in 0..<(keep.max() ?? 0) {
            let start = Date()
            let buffer = try #require(renderer.queue.makeCommandBuffer())
            let a = audio(f)
            renderer.render(into: screen, buffer: buffer, size: SIMD2(size.w, size.h), left: a, right: a, sampleRate: 44100, now: Double(f) / 60)
            Self.finish(buffer)
            if f > 0 { time += Date().timeIntervalSince(start) }
            if keep.contains(f + 1) {
                var bytes = [UInt8](repeating: 0, count: size.w * size.h * 4)
                screen.getBytes(&bytes, bytesPerRow: size.w * 4, from: MTLRegionMake2D(0, 0, size.w, size.h), mipmapLevel: 0)
                if format == .bgra8Unorm { for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) } }
                out[f + 1] = bytes
            }
        }
        return (out, time * 1000 / Double(max((keep.max() ?? 0) - 1, 1)))
    }

    /// Waits for the GPU; a plain call, as the async wait cannot take a command buffer across actors.
    nonisolated static func finish(_ buffer: MTLCommandBuffer) {
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    nonisolated static func savePNG(_ bytes: [UInt8], to url: URL) {
        let data = CFDataCreate(nil, bytes, bytes.count)!
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: size.w, height: size.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Presets to compare: `MILKDROP_PARITY=all` for every bundled one, `MILKDROP_PARITY=name|name` for those, else every 10th.
    /// `MILKDROP_PARITY_DIR` takes them from that folder and its subfolders instead, every `MILKDROP_PARITY_STEP`th (20).
    static func presets() throws -> [URL] {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MILKDROP_PARITY_DIR"] {
            let all = (FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
            return stride(from: 0, to: all.count, by: Int(env["MILKDROP_PARITY_STEP"] ?? "") ?? 20).map { all[$0] }
        }
        let folder = try #require(MilkDropResources.presets)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
        switch env["MILKDROP_PARITY"] {
        case "all": return files
        case let names?: return files.filter { names.split(separator: "|").contains(Substring($0.deletingPathExtension().lastPathComponent)) }
        case nil: return stride(from: 0, to: files.count, by: 10).map { files[$0] }
        }
    }

    /// The .milk text for butterchurn, with the shaders that parse printed in full parentheses (see `HLSLPrinter`).
    static func referenceMilk(_ milk: String, _ preset: Preset) -> String {
        var lines = milk.components(separatedBy: .newlines)
        for (prefix, hlsl) in [("warp_", preset.warp), ("comp_", preset.comp)] {
            guard let text = HLSLPrinter.parenthesized(hlsl) else { continue }
            lines.removeAll { $0.lowercased().hasPrefix(prefix) }
            lines += text.split(separator: "\n").enumerated().map { "\(prefix)\($0.offset + 1)=`\($0.element)" }
        }
        return lines.joined(separator: "\n")
    }

    /// The first line of an error, of the JavaScript message for one from the web view.
    static func reason(_ error: Error) -> String {
        let text = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? "\(error)"
        return String(text.prefix { $0 != "\n" }.prefix(120))
    }

    struct Row {
        let name: String, diffs: [Double], failure: String?
        var line: String { "\(diffs.map { String(format: "%6.1f", $0) }.joined(separator: " "))  \(name)\(failure.map { "  (\($0))" } ?? "")" }
    }

    @Test func matchesButterchurn() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        try? FileManager.default.removeItem(at: Self.report)
        try FileManager.default.createDirectory(at: Self.report, withIntermediateDirectories: true)
        let reference = Butterchurn()
        try await reference.load()
        try await reference.setImages(try #require(MilkDropResources.textures))
        var rows: [Row] = [], skipped: [String] = []
        for file in try Self.presets() {
            let preset = try PresetFile.load(file)
            let milk = Self.referenceMilk(String(decoding: try Data(contentsOf: file), as: UTF8.self), preset)
            let theirs: [Int: [UInt8]], ours: [Int: [UInt8]]
            do { theirs = try await reference.render(milk, width: Self.size.w, height: Self.size.h, frames: Self.frames.max()!, keep: Self.frames) }
            catch { skipped.append("\(preset.name)  (butterchurn: \(Self.reason(error)))"); continue }
            do { ours = try await Self.native(preset, device: device, keep: Self.frames) }
            catch { skipped.append("\(preset.name)  (native: \(Self.reason(error)))"); continue }
            var diffs: [Double] = []
            for f in Self.frames {
                guard let a = theirs[f], let b = ours[f] else { continue }
                diffs.append(Self.difference(a, b, width: Self.size.w, height: Self.size.h))
                let base = Self.report.appendingPathComponent("\(preset.name.prefix(60))-\(f)")
                Self.savePNG(a, to: base.appendingPathExtension("butterchurn.png"))
                Self.savePNG(b, to: base.appendingPathExtension("native.png"))
            }
            rows.append(Row(name: preset.name, diffs: diffs, failure: reference.failure ?? Self.knownReferenceFailures[preset.name]))
        }
        rows.sort { ($0.diffs.max() ?? 0) > ($1.diffs.max() ?? 0) }
        let failed = rows.filter { $0.failure != nil }
        rows.removeAll { $0.failure != nil }
        let summary = "difference 0…255 at frames \(Self.frames), worst first\n" + rows.map(\.line).joined(separator: "\n")
            + "\n\n\(failed.count) presets butterchurn gets wrong, not counted:\n" + failed.map(\.line).joined(separator: "\n")
            + "\n\n\(skipped.count) presets one side cannot render:\n" + skipped.joined(separator: "\n")
        try summary.write(to: Self.report.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print(summary)
        print("report: \(Self.report.path)")
        #expect(!rows.isEmpty || !failed.isEmpty)
        // Medians, so a few differences that butterchurn's own quirks cause do not fail it.
        for (index, limit) in [(0, 0.5), (2, 1.0)] {
            let diffs = rows.compactMap { $0.diffs.count > index ? $0.diffs[index] : nil }.sorted()
            #expect(diffs.isEmpty || diffs[diffs.count / 2] < limit, "median difference at frame \(Self.frames[index])")
        }
    }
}
