import Foundation
@testable import MilkDropKit
import Testing

@Suite struct ResourcesTests {
    @Test func bundledPresetsAndTextures() throws {
        let presets = try FileManager.default.contentsOfDirectory(at: #require(MilkDropResources.presets), includingPropertiesForKeys: nil)
        let textures = try FileManager.default.contentsOfDirectory(at: #require(MilkDropResources.textures), includingPropertiesForKeys: nil)
        #expect(presets.filter { $0.pathExtension == "milk" }.count > 500)
        #expect(textures.contains { $0.lastPathComponent == "worms.jpg" })
    }
}
