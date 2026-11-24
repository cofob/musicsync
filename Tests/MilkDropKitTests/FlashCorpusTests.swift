import Foundation
import Metal
@testable import MilkDropKit
import Testing

/// Measures all bundled presets and reports how many flash too much and how their looks spread. Slow (minutes):
/// run it with MILKDROP_FLASH_CORPUS=1; MILKDROP_FLASH_STRIDE=12 takes every 12th preset, MILKDROP_FLASH_LIMIT a count.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MILKDROP_FLASH_CORPUS"] == "1"))
struct FlashCorpusTests {
    @Test func reportsFlashingPresets() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let noise = Noise.makeTextures(device: device, queue: queue)
        let limit = ProcessInfo.processInfo.environment["MILKDROP_FLASH_LIMIT"].flatMap(Int.init) ?? .max
        let stride = ProcessInfo.processInfo.environment["MILKDROP_FLASH_STRIDE"].flatMap(Int.init) ?? 1  // every nth preset
        let all = PresetLibrary(folders: []).entries.values.sorted { $0.name < $1.name }
        let entries = Array(Swift.stride(from: 0, to: all.count, by: stride).map { all[$0] }.prefix(limit))
        var results: [(String, PresetMeasure)] = []
        await withTaskGroup(of: (String, PresetMeasure)?.self) { group in
            var next = entries.makeIterator()
            func add() {
                guard let entry = next.next() else { return }
                group.addTask {
                    guard let compiled = try? await CompiledPreset.compile(PresetFile.load(entry.url), device: device, screenFormat: MilkDropController.screenFormat),
                          let measure = try? PresetMeasurer.measure(compiled, device: device, noise: noise) else { return nil }
                    return (entry.name, measure)
                }
            }
            for _ in 0..<(ProcessInfo.processInfo.environment["MILKDROP_FLASH_WIDTH"].flatMap(Int.init) ?? 2) { add() }
            for await result in group {
                if let result { results.append(result) }
                add()
            }
        }
        results.sort { $0.0 < $1.0 }
        let failing = results.filter { !$0.1.flash.isSafe }
        print("FLASH corpus: \(results.count) of \(entries.count) measured, \(failing.count) flash too much")
        print("FLASH general>=3: \(results.filter { $0.1.flash.general >= 3 }.count), red>=3: \(results.filter { $0.1.flash.red >= 3 }.count), screen>=2: \(results.filter { $0.1.flash.screen >= 2 }.count)")
        for (name, m) in failing.sorted(by: { $0.1.flash.general > $1.1.flash.general }).prefix(15) {
            print("FLASH \(name): general \(m.flash.general) red \(m.flash.red) screen \(m.flash.screen)")
        }
        func spread(_ name: String, _ value: (PresetMeasure) -> Double) {
            let v = results.map { value($0.1) }.sorted()
            guard !v.isEmpty else { return }
            print("LOOK \(name): p5 \(v[v.count / 20]) median \(v[v.count / 2]) p95 \(v[v.count * 19 / 20])")
        }
        spread("brightness") { $0.look.brightness }
        spread("saturation") { $0.look.saturation }
        spread("warmth") { $0.look.warmth }
        spread("contrast") { $0.look.contrast }
        spread("motion") { $0.look.motion }
        spread("beatReaction") { $0.look.beatReaction }
        spread("arousal") { $0.mood.arousal }
        spread("valence") { $0.mood.valence }
        spread("tension") { $0.mood.tension }
        #expect(results.count > entries.count / 2)
    }
}
