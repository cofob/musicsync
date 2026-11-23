import Foundation
@testable import MilkDropKit
import Testing

@Suite struct PresetPackTests {
    @Test func extractsFilesFromTarGzip() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let root = dir.appendingPathComponent("pack-abc")
        let long = String(repeating: "Very Long Folder Name ", count: 6)
        try fm.createDirectory(at: root.appendingPathComponent("! Transition/\(long)"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Fractal"), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: root.appendingPathComponent("! Transition/\(long)/a.milk"))
        try Data(repeating: 7, count: 2000).write(to: root.appendingPathComponent("Fractal/b.milk"))
        let archive = dir.appendingPathComponent("pack.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--format", "pax", "-czf", archive.path, "-C", dir.path, "pack-abc"]
        try tar.run()
        tar.waitUntilExit()

        var files: [String: Data] = [:]
        let reader = TarGzip { files[$0] = $1 }
        let data = try Data(contentsOf: archive)
        for start in stride(from: 0, to: data.count, by: 100) { try reader.append(data.subdata(in: start..<min(start + 100, data.count))) }
        try reader.finish()
        #expect(files["pack-abc/! Transition/\(long)/a.milk"] == Data("one".utf8))
        #expect(files["pack-abc/Fractal/b.milk"]?.count == 2000)
        #expect(PresetPack.place("pack-abc/! Transition/\(long)/a.milk")! == ("Transition", "a.milk"))
        #expect(PresetPack.place("pack-abc/README.md") == nil)
    }

    @Test func categoriesAddUpToThePack() {
        #expect(PresetPack.categories.map(\.count).reduce(0, +) == 9795)
    }
}
