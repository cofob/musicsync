import CoreGraphics
import Foundation
import ImageIO
import Metal
@testable import MilkDropKit
import Testing

/// Renders presets with projectM 4 (a second, independent MilkDrop engine) and with MilkDropKit from the same audio,
/// time steps and random values (see `scripts/projectm-reference.sh`), and compares them. The engines differ in
/// audio analysis, textures and details, so this looks for gross bugs only: flips, wrong colors, black or blown-out
/// frames, broken shaders. Runs with `MILKDROP_PROJECTM=<tool>`, as printed by `scripts/projectm-reference.sh`; on
/// the presets of `ParityTests.presets()` and, with `MILKDROP_PARITY_DIR`, on every `MILKDROP_PARITY_STEP`th
/// (default 100th) preset in that folder. Images and a summary go to `report`.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MILKDROP_PROJECTM"] != nil))
struct ProjectMParityTests {
    static let report = FileManager.default.temporaryDirectory.appendingPathComponent("MilkDropProjectM", isDirectory: true)
    /// A frame differs grossly when both limits are passed: blurred difference 0…255 and luminance correlation.
    /// Set from all 541 bundled presets that both render: about 10% of them pass the limits in some frame, as the
    /// engines' audio analysis and waveform windows differ and feedback grows it (medians: difference 3.0, 20.5,
    /// 28.7 and correlation 0.79, 0.54, 0.52 at frames 1, 10, 30).
    nonisolated static let limits = (difference: 80.0, correlation: 0.2)
    /// Most a run may have: the share of presets that differ grossly, and the medians per frame.
    static let allowed = (gross: 0.15, difference: [6.0, 30.0, 40.0], correlation: [0.6, 0.35, 0.35])
    /// Presets where projectM is the one that is wrong, with why. They do not count.
    static let knownReferenceFailures: [String: String] = [:]

    /// Both pictures as 32×24 blocks of 8×8 pixels, blurred over 3×3 blocks: RGB values 0…255, rows top first.
    static func blocks(_ rgba: [UInt8], width: Int, height: Int) -> [SIMD3<Double>] {
        let (bw, bh) = (width / 8, height / 8)
        var mean = [SIMD3<Double>](repeating: .zero, count: bw * bh)
        for y in 0..<bh * 8 {
            for x in 0..<bw * 8 {
                let i = (y * width + x) * 4
                mean[(y / 8) * bw + x / 8] += SIMD3(Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2])) / 64
            }
        }
        return (0..<bh * bw).map { k in
            let (bx, by) = (k % bw, k / bw)
            var sum = SIMD3<Double>.zero, n = 0.0
            for y in max(by - 1, 0)...min(by + 1, bh - 1) { for x in max(bx - 1, 0)...min(bx + 1, bw - 1) { sum += mean[y * bw + x]; n += 1 } }
            return sum / n
        }
    }

    struct Score {
        /// Mean absolute RGB difference of the blurred blocks, 0…255.
        let difference: Double
        /// Pearson correlation of block luminance; 1 when both are flat, 0 when one only is.
        let correlation: Double
        /// The correlation with ours upside down, to tell a flip.
        let flipped: Double
        /// Mean luminance 0…255 of theirs and ours.
        let light: (theirs: Double, ours: Double)
        var gross: Bool { difference > ProjectMParityTests.limits.difference && correlation < ProjectMParityTests.limits.correlation }
    }

    static func score(_ theirs: [UInt8], _ ours: [UInt8], width: Int, height: Int) -> Score {
        let a = blocks(theirs, width: width, height: height), b = blocks(ours, width: width, height: height)
        let (bw, bh) = (width / 8, height / 8)
        let difference = zip(a, b).map { (p: SIMD3<Double>, q: SIMD3<Double>) -> Double in
            let d: SIMD3<Double> = p - q
            return (Swift.abs(d.x) + Swift.abs(d.y) + Swift.abs(d.z)) / 3
        }.reduce(0, +) / Double(a.count)
        let weights = SIMD3(0.299, 0.587, 0.114)
        let la = a.map { ($0 * weights).sum() }, lb = b.map { ($0 * weights).sum() }
        let lf = (0..<lb.count).map { lb[(bh - 1 - $0 / bw) * bw + $0 % bw] }
        func correlation(_ x: [Double], _ y: [Double]) -> Double {
            let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for (p, q) in zip(x, y) { sxy += (p - mx) * (q - my); sxx += (p - mx) * (p - mx); syy += (q - my) * (q - my) }
            // Flat: standard deviation under 2 levels.
            let flatX = sxx / Double(x.count) < 4, flatY = syy / Double(y.count) < 4
            if flatX || flatY { return flatX && flatY ? 1 : 0 }
            return sxy / (sxx * syy).squareRoot()
        }
        return Score(difference: difference, correlation: correlation(la, lb), flipped: correlation(la, lf),
                     light: (la.reduce(0, +) / Double(la.count), lb.reduce(0, +) / Double(lb.count)))
    }

    /// RGBA bytes, rows top first, of a PNG.
    static func loadPNG(_ url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// The frames of `file` rendered by the projectM tool, or why it cannot.
    static func projectM(_ tool: String, _ file: URL, keep: [Int]) throws -> [Int: [UInt8]] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("projectm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = [file.path, out.path, keep.map(String.init).joined(separator: ","), MilkDropResources.textures?.path ?? ""]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "projectM", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"])
        }
        var frames: [Int: [UInt8]] = [:]
        for f in keep { frames[f] = loadPNG(out.appendingPathComponent("\(f).png"), width: ParityTests.size.w, height: ParityTests.size.h) }
        return frames
    }

    /// `ParityTests.presets()` and every `MILKDROP_PARITY_STEP`th preset under `MILKDROP_PARITY_DIR`.
    static func presets() throws -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var files = try ParityTests.presets()
        if let dir = env["MILKDROP_PARITY_DIR"] {
            let stride = max(Int(env["MILKDROP_PARITY_STEP"] ?? "") ?? 100, 1)
            let all = (FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
            files += Swift.stride(from: 0, to: all.count, by: stride).map { all[$0] }
        }
        return files
    }

    struct Row {
        let name: String, scores: [Score]
        var worst: Score { scores.max { $0.difference * (1 - $0.correlation) < $1.difference * (1 - $1.correlation) }! }
        var line: String {
            scores.map { String(format: "%5.1f %5.2f", $0.difference, $0.correlation) }.joined(separator: " | ")
                + String(format: "  light %3.0f/%3.0f flip %5.2f  ", worst.light.theirs, worst.light.ours, worst.flipped) + name
        }
    }

    @Test func matchesProjectM() async throws {
        let tool = try #require(ProcessInfo.processInfo.environment["MILKDROP_PROJECTM"])
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        try? FileManager.default.removeItem(at: Self.report)
        try FileManager.default.createDirectory(at: Self.report, withIntermediateDirectories: true)
        let (w, h) = (ParityTests.size.w, ParityTests.size.h)
        var rows: [Row] = [], skipped: [String] = []
        for file in try Self.presets() {
            let theirs: [Int: [UInt8]], ours: [Int: [UInt8]]
            let name = file.deletingPathExtension().lastPathComponent
            do { theirs = try Self.projectM(tool, file, keep: ParityTests.frames) }
            catch { skipped.append("\(name)  (projectM: \(ParityTests.reason(error)))"); continue }
            do { ours = try await ParityTests.native(try PresetFile.load(file), device: device, keep: ParityTests.frames) }
            catch { skipped.append("\(name)  (native: \(ParityTests.reason(error)))"); continue }
            var scores: [Score] = []
            for f in ParityTests.frames {
                guard let a = theirs[f], let b = ours[f] else { continue }
                scores.append(Self.score(a, b, width: w, height: h))
                let base = Self.report.appendingPathComponent("\(name.prefix(60))-\(f)")
                ParityTests.savePNG(a, to: base.appendingPathExtension("projectm.png"))
                ParityTests.savePNG(b, to: base.appendingPathExtension("native.png"))
            }
            if !scores.isEmpty { rows.append(Row(name: name, scores: scores)) }
        }
        rows.sort { $0.worst.difference * (1 - $0.worst.correlation) > $1.worst.difference * (1 - $1.worst.correlation) }
        let known = rows.filter { Self.knownReferenceFailures[$0.name] != nil }
        rows.removeAll { Self.knownReferenceFailures[$0.name] != nil }
        let gross = rows.filter { $0.scores.contains(where: \.gross) }
        func median(_ index: Int, _ value: (Score) -> Double) -> Double {
            let v = rows.compactMap { $0.scores.count > index ? value($0.scores[index]) : nil }.sorted()
            return v.isEmpty ? 0 : v[v.count / 2]
        }
        let medians = ParityTests.frames.indices.map { String(format: "frame %d: difference %.1f, correlation %.2f", ParityTests.frames[$0], median($0, \.difference), median($0, \.correlation)) }
        let summary = "blurred difference 0…255 and luminance correlation at frames \(ParityTests.frames), worst first\n"
            + rows.map(\.line).joined(separator: "\n")
            + "\n\nmedians (\(rows.count) presets): " + medians.joined(separator: "; ")
            + "\n\n\(gross.count) presets past the limits \(Self.limits):\n" + gross.map(\.line).joined(separator: "\n")
            + "\n\n\(known.count) presets projectM gets wrong, not counted:\n" + known.map { "\($0.line)  (\(Self.knownReferenceFailures[$0.name]!))" }.joined(separator: "\n")
            + "\n\n\(skipped.count) presets one side cannot render:\n" + skipped.joined(separator: "\n")
        try summary.write(to: Self.report.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        print(summary)
        print("report: \(Self.report.path)")
        // A few presets differ grossly as the engines differ; a bug that hits many (flip, colors, black) moves these.
        #expect(!rows.isEmpty)
        #expect(Double(gross.count) <= Self.allowed.gross * Double(rows.count), "share of presets that differ grossly")
        for index in ParityTests.frames.indices {
            #expect(median(index, \.difference) < Self.allowed.difference[index], "median difference at frame \(ParityTests.frames[index])")
            #expect(median(index, \.correlation) > Self.allowed.correlation[index], "median correlation at frame \(ParityTests.frames[index])")
        }
    }
}
