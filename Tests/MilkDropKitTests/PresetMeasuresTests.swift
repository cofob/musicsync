import Foundation
import Metal
@testable import MilkDropKit
import Support
import Testing

@Suite struct PresetMeasuresTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[preset00]\nper_frame_1=zoom = 1.01;\n".utf8).write(to: dir.appendingPathComponent("A.milk"))
        return dir
    }

    private let measure = PresetMeasure(
        look: PresetLook(brightness: 0.4, saturation: 0.5, warmth: 0.2, contrast: 0.1, motion: 0.02, beatReaction: 0.3),
        flash: FlashReport(general: 4, red: 0, screen: 0))

    @Test func storeRoundTripsByFileStamp() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("measures/measures.json")
        let entry = try #require(PresetLibrary(builtIn: nil, folders: [dir]).entries["A"])
        let store = PresetMeasures(url: url)
        #expect(store.measure(entry) == nil && store.isSafe(entry) == nil)
        store.record(entry, measure)
        store.save()

        let again = PresetMeasures(url: url)
        #expect(again.measure(entry) == measure)
        #expect(again.mood(entry) == measure.look.mood && again.isSafe(entry) == false)

        // A changed file is measured again.
        try Data("[preset00]\nper_frame_1=zoom = 1.02;\n".utf8).write(to: dir.appendingPathComponent("A.milk"))
        let changed = try #require(PresetLibrary(builtIn: nil, folders: [dir]).entries["A"])
        #expect(again.measure(changed) == nil)
    }

    @Test func fileOfAnotherVersionIsEmpty() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("measures.json")
        let entry = try #require(PresetLibrary(builtIn: nil, folders: [dir]).entries["A"])
        let store = PresetMeasures(url: url)
        store.record(entry, measure)
        store.save()
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"version\":\(PresetMeasures.version)", with: "\"version\":\(PresetMeasures.version + 1)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(PresetMeasures(url: url).measure(entry) == nil)
    }

    @Test func measuresARealPreset() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let entry = try #require(PresetLibrary(folders: []).entries.values.sorted { $0.name < $1.name }.first)
        let compiled = try await CompiledPreset.compile(PresetFile.load(entry.url), device: device, screenFormat: MilkDropController.screenFormat)
        let result = try PresetMeasurer.measure(compiled, device: device, noise: nil)
        #expect(result.look.brightness > 0)
        #expect(0...1 ~= result.mood.arousal && 0...1 ~= result.mood.valence && 0...1 ~= result.mood.tension)
    }
}
