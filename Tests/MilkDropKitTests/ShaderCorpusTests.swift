import Foundation
import Metal
@testable import MilkDropKit
import Testing

/// Shader text of a .milk file: the `warp_N`/`comp_N` lines in order, when `PSVERSION_WARP`/`PSVERSION_COMP` > 0.
func presetShader(_ url: URL, _ stage: ShaderStage) throws -> String? {
    let key = stage == .warp ? "warp" : "comp"
    var values: [String: String] = [:]
    for line in try String(contentsOf: url, encoding: .isoLatin1).components(separatedBy: .newlines) {
        guard let eq = line.firstIndex(of: "=") else { continue }
        let name = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
        if values[name] == nil { values[name] = String(line[line.index(after: eq)...]) }
    }
    guard let version = values["psversion_\(key)"].flatMap(Double.init), version > 0 else { return nil }
    var lines: [String] = []
    while let line = values["\(key)_\(lines.count + 1)"] { lines.append(line.hasPrefix("`") ? String(line.dropFirst()) : line) }
    return lines.isEmpty ? nil : lines.joined(separator: "\n") // no lines: the default shader, as CompiledPreset does
}

/// Compiles MSL and returns the error text, or nil when it compiles.
func metalError(_ source: String, _ device: MTLDevice) -> String? {
    do {
        let library = try device.makeLibrary(source: source, options: nil)
        guard library.makeFunction(name: "md_vertex") != nil, library.makeFunction(name: "md_fragment") != nil else { return "missing functions" }
        return nil
    } catch {
        return "\(error)"
    }
}

@Suite struct ShaderCorpusTests {
    @Test func bundledPresetShadersTranslateAndCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let presets = try FileManager.default.contentsOfDirectory(at: #require(MilkDropResources.presets), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "milk" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var total = 0
        var failures: [String] = []
        for url in presets {
            for stage in [ShaderStage.warp, .comp] {
                guard let hlsl = try presetShader(url, stage) else { continue }
                total += 1
                do {
                    let shader = try HLSLTranslator.translate(hlsl, stage: stage)
                    if let error = metalError(shader.source, device) {
                        failures.append("\(url.lastPathComponent) [\(stage)] Metal: \(error.prefix(600))")
                    }
                } catch {
                    failures.append("\(url.lastPathComponent) [\(stage)] translate: \(error)")
                }
            }
        }
        for failure in failures { print("FAIL", failure) }
        let rate = Double(total - failures.count) / Double(max(total, 1))
        print("shader corpus: \(total - failures.count)/\(total) compile (\(String(format: "%.1f", rate * 100))%)")
        #expect(total > 400)
        #expect(rate >= 0.95)
    }
}

/// Translates and compiles the warp and comp shaders of every preset under `MILKDROP_PACK_DIR` and lists the failures by error.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MILKDROP_PACK_DIR"] != nil))
struct PackShaderCorpusTests {
    @Test func packShadersTranslateAndCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let dir = ProcessInfo.processInfo.environment["MILKDROP_PACK_DIR"] else { return }
        let urls = (FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
        let jobs = try urls.flatMap { url in
            try [ShaderStage.warp, .comp].compactMap { stage in try presetShader(url, stage).map { ("\(url.lastPathComponent) [\(stage)]", stage, $0) } }
        }
        var results = [String?](repeating: nil, count: jobs.count)
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                do {
                    let shader = try HLSLTranslator.translate(jobs[i].2, stage: jobs[i].1)
                    out[i] = metalError(shader.source, device).map { m in
                        m.components(separatedBy: "error: ").dropFirst().first.map { "Metal: " + $0.prefix { $0 != "\n" } } ?? m
                    }
                } catch {
                    out[i] = "translate: \(error)"
                }
            }
        }
        let failures = Dictionary(grouping: zip(jobs, results).compactMap { job, error in error.map { ($0, job.0) } }, by: \.0)
        for (error, names) in failures.sorted(by: { $0.value.count > $1.value.count }) {
            print("PACKSHADER \(names.count)x \(error)\n    " + names.map(\.1).joined(separator: "\n    "))
        }
        let failed = results.compactMap { $0 }.count
        print("PACKSHADER \(jobs.count - failed)/\(jobs.count) compile, \(failed) fail")
        #expect(failed <= 5)
    }
}
