import Foundation
@testable import MilkDropKit
import Support
import Testing

@MainActor @Suite struct ReduceFlashingTests {
    private func measure(general: Double, arousal: Double = 0.5) -> PresetMeasure {
        PresetMeasure(look: PresetLook(brightness: 0.3, saturation: 0.5, warmth: 0, contrast: 0.1, motion: arousal * 0.05, beatReaction: 0),
                      flash: FlashReport(general: general, red: 0, screen: 0))
    }

    /// A folder with presets A…L, and a controller that sees only them.
    private func setUp(_ body: (MilkDropController, [PresetLibrary.Entry], PresetMeasures) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in "ABCDEFGHIJKL".map(String.init) {
            try Data("[preset00]\nper_frame_1=zoom = 1.01;\n".utf8).write(to: dir.appendingPathComponent("\(name).milk"))
        }
        let url = dir.appendingPathComponent("measures.json")
        let entries = PresetLibrary(builtIn: nil, folders: [dir]).entries.values.sorted { $0.name < $1.name }
        let measures = PresetMeasures.at(url)
        let controller = MilkDropController(folders: [dir], measures: url)
        var options = PresetCycler.Options()
        options.builtIn = false
        controller.configure(options)
        try body(controller, entries, measures)
    }

    @Test func leavesOutPresetsThatFlashOrAreNotMeasured() throws {
        try setUp { controller, entries, measures in
            measures.record(entries[0], measure(general: 0))
            measures.record(entries[1], measure(general: 5))
            var options = PresetCycler.Options()
            options.builtIn = false
            #expect(controller.presets.count == 12)
            options.reduceFlashing = true
            controller.configure(options)
            #expect(controller.presets == ["A"])
            #expect(controller.unmeasured == 10)
            #expect(controller.flashes(entries[1]) == true && controller.flashes(entries[0]) == false && controller.flashes(entries[2]) == nil)
            options.reduceFlashing = false
            controller.configure(options)
            #expect(controller.presets.count == 12)
        }
    }

    @Test func matchingNeedsEnoughMoods() throws {
        try setUp { controller, entries, measures in
            for entry in entries.prefix(3) { measures.record(entry, measure(general: 0)) }
            #expect(!controller.random(matching: Mood(arousal: 0.5, valence: 0.5, tension: 0.5)))
            for entry in entries { measures.record(entry, measure(general: 0)) }
            controller.reload()
            #expect(controller.random(matching: Mood(arousal: 0.5, valence: 0.5, tension: 0.5)))
        }
    }
}
