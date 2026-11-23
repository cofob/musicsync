import Foundation
@testable import MilkDropKit
import Testing

@Suite struct PresetEquationsTests {
    private func preset(_ text: String) -> Preset { PresetFile.parse("[preset00]\nzoom=1.5\n" + text, name: "T") }

    @Test func lifetimesFollowButterchurn() throws {
        let p = preset("""
        per_frame_init_1=q1 = 7; mine = 10;
        per_frame_1=zoom = zoom + 1; q1 = q1 + 1; mine = mine + 1; reg05 = reg05 + 1;
        per_pixel_1=zoom = 9; mine = 100;
        """)
        let globals = EELGlobals()
        let eq = try PresetEquations(p, globals: globals, frame: FrameGlobals())
        var mesh = WarpMesh(size: SIMD2(4, 3))
        eq.runFrame(FrameGlobals())
        #expect(eq.values["zoom"] == 2.5)  // file value again, then + 1
        #expect(eq.q[0] == 8)  // init value again, then + 1
        #expect(eq.scope["mine"] == 12)  // own variable carries over (init, first frame at load, this frame)
        mesh.update(eq, time: 0, aspect: SIMD2(1, 1))
        #expect(eq.scope["mine"] == 12)  // per-pixel changes undone
        eq.runFrame(FrameGlobals())
        #expect(eq.scope["mine"] == 13)
        #expect(eq.scope["reg05"] == 3)
    }

    @Test func centerOfPlainZoomSamplesItself() throws {
        let eq = try PresetEquations(preset("warp=0"), globals: EELGlobals(), frame: FrameGlobals())
        var mesh = WarpMesh(size: SIMD2(4, 4))
        mesh.update(eq, time: 0, aspect: SIMD2(1, 1))
        let center = mesh.uvs[2 * 5 + 2], corner = mesh.uvs[0]
        #expect(abs(center.x - 0.5) < 1e-6 && abs(center.y - 0.5) < 1e-6)
        #expect(corner.x > 0 && corner.x < 0.5)  // zoom 1.5 samples inward
        #expect(mesh.vertices(alpha: false).count == 5 * 5 * WarpMesh.floatsPerVertex && WarpMesh.indices(SIMD2(4, 4)).count == 4 * 4 * 6)
    }

    @Test func bundledPresetsRunAFrame() throws {
        let folder = try #require(MilkDropResources.presets)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "milk" }
        let globals = EELGlobals()
        var mesh = WarpMesh(size: SIMD2(48, 36))
        let start = Date()
        for file in files {
            let eq = try PresetEquations(PresetFile.load(file), globals: globals, frame: FrameGlobals())
            eq.runFrame(FrameGlobals(time: 1, frame: 2))
            mesh.update(eq, time: 1, aspect: SIMD2(1, 0.75))
        }
        print("frame + mesh for \(files.count) presets: \(Date().timeIntervalSince(start)) s")
    }
}
