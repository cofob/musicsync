import Foundation
import Metal
@testable import MilkDropKit
import Testing

@Suite struct RendererTests {
    static func screen(_ device: MTLDevice, _ w: Int = 320, _ h: Int = 200) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// Mean brightness 0…255 of the screen texture.
    static func brightness(_ t: MTLTexture) -> Double {
        var bytes = [UInt8](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&bytes, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return Double(bytes.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }.reduce(0, +)) / Double(t.width * t.height * 3)
    }

    /// Renders `frames` frames of a loud sine with `preset`; returns the mean brightness of the last one.
    static func render(_ preset: Preset, frames: Int, renderer: Renderer, screen: MTLTexture) async throws -> Double {
        let compiled = try await CompiledPreset.compile(preset, device: renderer.device, screenFormat: .bgra8Unorm)
        try renderer.show(compiled, blend: 0)
        for i in 0..<frames {
            let tone = (0..<1024).map { Float(0.6 * sin(Double(i * 1024 + $0) * 0.05)) }
            let buffer = try #require(renderer.queue.makeCommandBuffer())
            renderer.render(into: screen, buffer: buffer, size: SIMD2(screen.width, screen.height), left: tone, right: tone,
                            sampleRate: 44100, now: Double(i) / 60)
            buffer.commit()
            await buffer.completed()
            #expect(buffer.status == .completed, "\(preset.name)")
        }
        return brightness(screen)
    }

    @Test func rendersBundledPresets() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let screen = Self.screen(device) else { return }
        let renderer = try #require(Renderer(device: device))
        let folder = try #require(MilkDropResources.presets)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "milk" }.sorted { $0.path < $1.path }
        let sample = stride(from: 0, to: files.count, by: 20).map { files[$0] }
        var dark: [String] = []
        let start = Date()
        for file in sample {
            let preset = try PresetFile.load(file)
            if try await Self.render(preset, frames: 30, renderer: renderer, screen: screen) < 1 { dark.append(preset.name) }
        }
        print("rendered \(sample.count) presets × 30 frames in \(Date().timeIntervalSince(start)) s; dark: \(dark)")
        #expect(dark.count <= sample.count / 4)
    }

    /// A far-zoomed video echo reads small mip levels of the frame; on the first frame they must be black too.
    @Test func firstFrameEchoIsBlack() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let screen = Self.screen(device) else { return }
        let renderer = try #require(Renderer(device: device))
        let preset = PresetFile.parse("[preset00]\nfWaveAlpha=0\nfVideoEchoAlpha=1\nfVideoEchoZoom=0.25\nfGammaAdj=1\nmv_a=0\nob_a=0\nib_a=0", name: "T")
        #expect(try await Self.render(preset, frames: 1, renderer: renderer, screen: screen) < 0.5)
    }

    @Test func blendsTwoPresets() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let screen = Self.screen(device) else { return }
        let renderer = try #require(Renderer(device: device))
        let folder = try #require(MilkDropResources.presets)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "milk" }
        _ = try await Self.render(PresetFile.load(files[0]), frames: 5, renderer: renderer, screen: screen)
        let next = try await CompiledPreset.compile(PresetFile.load(files[1]), device: device, screenFormat: .bgra8Unorm)
        try renderer.show(next, blend: 0.5)
        renderer.showTitle("Artist - Title", seconds: 0.3)
        for i in 0..<40 {
            let buffer = try #require(renderer.queue.makeCommandBuffer())
            renderer.render(into: screen, buffer: buffer, size: SIMD2(320, 200), left: [], right: [], sampleRate: 48000, now: 1 + Double(i) / 60)
            buffer.commit()
            await buffer.completed()
            #expect(buffer.status == .completed)
        }
    }
}
