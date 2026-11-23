import CoreGraphics
import Foundation
import Metal
@testable import MilkDropKit
import Testing

@Suite struct ThumbnailTests {
    @Test func categoriesFromFolders() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("Fractal"), withIntermediateDirectories: true)
        try Data("[preset00]\n".utf8).write(to: dir.appendingPathComponent("Fractal/A.milk"))
        try Data("[preset00]\n".utf8).write(to: dir.appendingPathComponent("Mine.milk"))
        let library = PresetLibrary(folders: [dir])
        #expect(library.categories == ["Built-in", "My Presets", "Fractal"])
        #expect(library.entries["A"]?.category == "Fractal" && library.entries["Mine"]?.category == "My Presets")
    }

    @Test func demoTrackRepeatsAndIsLoud() {
        #expect(DemoTrack.samples(frame: 7) == DemoTrack.samples(frame: 7))
        let peak = (0..<60).flatMap { DemoTrack.samples(frame: $0) }.map(abs).max() ?? 0
        #expect(peak > 0.5 && peak <= 1)
    }

    @Test func makesAndCachesPictures() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let entry = try #require(PresetLibrary(folders: []).entries.values.sorted { $0.name < $1.name }.first)
        let store = ThumbnailStore(folder: dir, index: nil)
        let image = try #require(await store.thumbnail(entry))
        #expect(image.width == PresetThumbnails.size.x && image.height == PresetThumbnails.size.y)
        #expect(PresetThumbnails(folder: dir).cached(entry) != nil)
        #expect(Self.brightness(image) > 1)  // not a black picture
    }

    static func brightness(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Double(bytes.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }.reduce(0, +)) / Double(w * h * 3)
    }
}
