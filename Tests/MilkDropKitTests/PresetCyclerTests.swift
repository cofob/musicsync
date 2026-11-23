import Foundation
@testable import MilkDropKit
import Testing

@Suite struct PresetCyclerTests {
    private func cycler(shuffle: Bool) -> PresetCycler {
        var c = PresetCycler(random: { 0.5 })
        var o = PresetCycler.Options()
        o.shuffle = shuffle
        o.seconds = 10
        c.setOptions(o)
        c.setNames(["a", "b", "c", "d"])
        return c
    }

    @Test func alphabeticalSteps() {
        var c = cycler(shuffle: false)
        #expect(c.select("d", now: 0)?.name == "d")
        #expect(c.upcoming == "a")
        #expect(c.step(1, now: 1)?.name == "a")
        #expect(c.step(-1, now: 2)?.name == "d")
    }

    @Test func timerChangesWhenDue() {
        var c = cycler(shuffle: false)
        _ = c.select("a", now: 0)
        #expect(c.tick(now: 5) == nil)
        #expect(c.tick(now: 11) == .init(name: "b", blend: 2.7))
    }

    @Test func randomShowsTheUpcomingPreset() {
        var c = cycler(shuffle: true)
        let upcoming = c.upcoming
        #expect(c.random(now: 0)?.name == upcoming)
    }

    @Test func droppedCurrentMovesOn() {
        var c = cycler(shuffle: false)
        _ = c.select("b", now: 0)
        #expect(c.drop("b", now: 1)?.name == "c")
        #expect(c.names == ["a", "c", "d"])
    }

    @Test func libraryHidesBuiltInOnlyWhenAskedAndHasOwn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Fractal"), withIntermediateDirectories: true)
        try Data("[preset00]\n".utf8).write(to: dir.appendingPathComponent("Fractal/Mine.milk"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = PresetLibrary(folders: [dir])
        #expect(library.names(includingBuiltIn: false) == ["Mine"])
        #expect(library.names(includingBuiltIn: true).count > 500)
        #expect(PresetLibrary(folders: []).names(includingBuiltIn: false).count > 500)
    }
}
