import Foundation
import Metal
@testable import MilkDropKit
import Testing

@MainActor @Suite struct PrecompilerTests {
    @Test func compilesFolderAndRemembersFailures() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[preset00]\nper_frame_1=zoom = 1.01;\n".utf8).write(to: dir.appendingPathComponent("Good.milk"))
        // A file that cannot be read: about the only preset that cannot run, since broken code and shaders are skipped.
        try Data("[preset00]\n".utf8).write(to: dir.appendingPathComponent("Broken.milk"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.appendingPathComponent("Broken.milk").path)
        let indexURL = dir.appendingPathComponent("index/compiled.json")

        let compiler = PresetPrecompiler(folders: [dir], index: indexURL)
        await withCheckedContinuation { done in compiler.compileAll(only: ["Good", "Broken"]) { done.resume() } }
        #expect(compiler.total == 2 && compiler.done == 2 && compiler.failed == 1)

        let library = PresetLibrary(folders: [dir])
        let index = CompileIndex.at(indexURL)
        #expect(index.failed(in: library) == ["Broken"])
        #expect(index.status(try #require(library.entries["Good"])) == true)
        #expect(fm.fileExists(atPath: indexURL.path))

        // A changed file is not known any more.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("Broken.milk").path)
        try Data("[preset00]\nper_frame_1=zoom = 1.02;\n".utf8).write(to: dir.appendingPathComponent("Broken.milk"))
        #expect(index.status(try #require(PresetLibrary(folders: [dir]).entries["Broken"])) == nil)

        // The visualizer leaves known failures out from the start.
        try Data("[preset00]\nper_frame_1=zoom = (1 +;\n".utf8).write(to: dir.appendingPathComponent("Broken2.milk"))
        let entry = try #require(PresetLibrary(folders: [dir]).entries["Broken2"])
        index.record(entry, ok: false)
        let controller = MilkDropController(folders: [dir], index: indexURL)
        #expect(controller.failed.contains("Broken2") && !controller.presets.contains("Broken2"))
    }

    /// As MilkDrop: a shader that does not compile runs on the default shader of its stage; the preset still shows.
    @Test func brokenShaderFallsBackToDefault() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let preset = PresetFile.parse("[preset00]\nPSVERSION_COMP=2\ncomp_1=`shader_body { ret = nonsense(; }\n", name: "b")
        let compiled = try await CompiledPreset.compile(preset, device: device, screenFormat: .bgra8Unorm)
        #expect(compiled.fallbacks.count == 1 && compiled.fallbacks[0].hasPrefix("comp:"))
    }
}
