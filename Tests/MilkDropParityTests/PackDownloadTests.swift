import Foundation
@testable import MilkDropKit
import Testing

/// Downloads the whole Cream of the Crop pack from GitHub and compiles every preset ahead. Network and minutes:
/// runs only with `MILKDROP_NETWORK=1`.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["MILKDROP_NETWORK"] == "1"))
struct PackDownloadTests {
    @Test func downloadAndCompileAll() async throws {
        let fm = FileManager.default
        // MILKDROP_PACK_DIR keeps the pack (and reuses it) for work on the presets that fail.
        let kept = ProcessInfo.processInfo.environment["MILKDROP_PACK_DIR"].map { URL(fileURLWithPath: $0) }
        let dir = kept ?? fm.temporaryDirectory.appendingPathComponent("MilkDropPack-\(UUID().uuidString)")
        defer { if kept == nil { try? fm.removeItem(at: dir) } }
        var t = Date()
        let have = PresetPack.installed(in: dir).values.reduce(0, +)
        let saved = have > 9000 ? have : try await PresetPack.download(Set(PresetPack.categories.map(\.name)), to: dir)
        let download = Date().timeIntervalSince(t)
        let installed = PresetPack.installed(in: dir)
        let size = (fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)) ?? 0
        print("PACK downloaded \(saved) presets in \(String(format: "%.1f", download)) s, \(size / 1_048_576) MB on disk: \(installed.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        #expect(saved > 9000)
        #expect(installed.count == PresetPack.categories.count)

        let names = Set(PresetLibrary(builtIn: nil, folders: [dir]).entries.keys)
        let indexURL = dir.appendingPathComponent("compiled-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: indexURL) }
        let compiler = PresetPrecompiler(folders: [dir], index: indexURL)
        t = Date()
        await withCheckedContinuation { done in compiler.compileAll(only: names) { done.resume() } }
        let compile = Date().timeIntervalSince(t)
        print("PACK compiled \(compiler.done) presets in \(String(format: "%.0f", compile)) s (\(String(format: "%.1f", compile / Double(max(compiler.done, 1)) * 1000)) ms each, several at once); \(compiler.failed) do not compile (\(String(format: "%.1f", Double(compiler.failed) / Double(max(compiler.done, 1)) * 100))%)")

        // Why they fail: first words of the errors.
        if let data = try? Data(contentsOf: indexURL), let records = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            var reasons: [String: Int] = [:]
            for record in records.values where record["ok"] as? Bool == false {
                let error = (record["error"] as? String ?? "?").replacingOccurrences(of: "\n", with: " ")
                reasons[String(error.prefix(70)), default: 0] += 1
            }
            for (reason, count) in reasons.sorted(by: { $0.value > $1.value }).prefix(12) { print("PACK fail \(count): \(reason)") }
            // Every failing preset with its whole error, for whoever fixes them.
            let lines = records.filter { $0.value["ok"] as? Bool == false }.sorted { $0.key < $1.key }
                .map { "\($0.key)\t\(($0.value["error"] as? String ?? "?").replacingOccurrences(of: "\n", with: " | "))" }
            try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("failures.tsv"), atomically: true, encoding: .utf8)
        }

        // Shown again later: from the shader cache.
        let sample = Array(names.sorted().prefix(50))
        let again = PresetPrecompiler(folders: [dir], index: dir.appendingPathComponent("again.json"))
        t = Date()
        await withCheckedContinuation { done in again.compileAll(only: Set(sample)) { done.resume() } }
        print("PACK again, \(sample.count) presets from the cache: \(String(format: "%.1f", Date().timeIntervalSince(t) / Double(sample.count) * 1000)) ms each")
        #expect(Double(compiler.failed) / Double(max(compiler.done, 1)) < 0.2)
    }
}
