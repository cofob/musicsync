import Foundation
@testable import MilkDropKit
import Testing

/// Code blocks of a .milk file, by block name (`per_frame`, `per_pixel`, `wave_0_per_point`...).
func milkCodeBlocks(_ text: String) -> [String: String] {
    let key = /^(per_frame_init|per_frame|per_pixel)_\d+$|^((?:wave|shape)_\d+_(?:init|per_frame|per_point))\d+$/
    var lines: [String: [String]] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        guard let eq = line.firstIndex(of: "="), let match = line[..<eq].wholeMatch(of: key) else { continue }
        lines[String(match.1 ?? match.2!), default: []].append(String(line[line.index(after: eq)...]))
    }
    return lines.mapValues(EELScope.joinCodeLines)
}

func bundledPresets() throws -> [(name: String, text: String)] {
    try FileManager.default.contentsOfDirectory(at: #require(MilkDropResources.presets), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "milk" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { ($0.lastPathComponent, String(decoding: try Data(contentsOf: $0), as: UTF8.self)) }
}

@Suite struct EELCorpusTests {
    @Test func everyBundledPresetCompiles() throws {
        var blocks = 0
        var failures: [String] = []
        for preset in try bundledPresets() {
            let scope = EELScope(memory: EELMemory(), globals: EELGlobals())
            for (name, code) in milkCodeBlocks(preset.text) {
                blocks += 1
                do { _ = try scope.compile(code) } catch { failures.append("\(preset.name) \(name): \(error)") }
            }
        }
        print("EEL corpus: \(blocks - failures.count)/\(blocks) blocks compile")
        failures.forEach { print("  \($0)") }
        #expect(blocks > 3000)
        #expect(failures.isEmpty)
    }

    /// Runs every bundled per-pixel program 2000 times, as for a 2000-vertex mesh.
    @Test func perPixelSpeed() throws {
        var programs: [(String, EELScope, EELProgram)] = []
        for preset in try bundledPresets() {
            guard let code = milkCodeBlocks(preset.text)["per_pixel"] else { continue }
            let scope = EELScope(memory: EELMemory(), globals: EELGlobals())
            programs.append((preset.name, scope, try scope.compile(code)))
        }
        let clock = ContinuousClock()
        var worst = (Duration.zero, "")
        let total = clock.measure {
            for (name, scope, program) in programs {
                let x = scope.slot("x"), y = scope.slot("y"), rad = scope.slot("rad")
                let time = clock.measure {
                    for i in 0..<2000 {
                        scope[x] = Double(i % 40) / 40
                        scope[y] = Double(i / 40) / 50
                        scope[rad] = 0.5
                        scope.run(program)
                    }
                }
                if time > worst.0 { worst = (time, name) }
            }
        }
        print("EEL per-pixel × 2000: \(programs.count) presets, mean \(total / programs.count), worst \(worst.0) (\(worst.1))")
        #expect(programs.count > 100)
    }
}

/// Compiles every equation block of every .milk under `MILKDROP_PACK_DIR` (the downloaded pack) and lists the failures.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MILKDROP_PACK_DIR"] != nil))
struct EELPackTests {
    @Test func everyPackPresetCompiles() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MILKDROP_PACK_DIR"]!)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "milk" }
        var failures: [String] = []
        for file in files {
            let preset = try PresetFile.load(file)
            let blocks = [preset.initCode, preset.frameCode, preset.pixelCode]
                + preset.waves.flatMap { [$0.initCode, $0.frameCode, $0.pointCode] } + preset.shapes.flatMap { [$0.initCode, $0.frameCode] }
            let scope = EELScope(memory: EELMemory(), globals: EELGlobals())
            for code in blocks {
                do { _ = try scope.compile(code) } catch {
                    failures.append("\(file.path.dropFirst(root.path.count))\t\(error)")
                    break
                }
            }
        }
        print("EEL pack: \(files.count - failures.count)/\(files.count) presets compile")
        failures.sorted().forEach { print("  \($0)") }
        #expect(files.count > 0)
    }
}
