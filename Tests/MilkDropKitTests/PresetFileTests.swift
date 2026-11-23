import Foundation
@testable import MilkDropKit
import Testing

@Suite struct PresetFileTests {
    static let sample = """
    [preset00]
    fRating=3.000000
    fDecay=0.950000
    nWaveMode=5
    bTexWrap=0
    nMotionVectorsX=12.000000
    MILKDROP_PRESET_VERSION=201
    wavecode_1_enabled=1
    wavecode_1_bSpectrum=1
    shapecode_3_num_inst=4
    per_frame_2=b = 2;
    per_frame_1=a = 1;
    per_frame_init_1=q1 = 3;
    per_pixel_1=zoom = zoom + rad*0.1;
    wave_1_per_point1=x = sample;
    shape_3_per_frame1=ang = instance;
    warp_1=`shader_body {
    warp_2=`  ret = tex2D(sampler_main, uv).xyz;
    warp_3=`}
    """

    @Test func readsValuesAndCode() {
        let p = PresetFile.parse(Self.sample, name: "Test")
        #expect(p.version == 2)
        #expect(p.values["decay"] == 0.95)
        #expect(p.values["wave_mode"] == 5)
        #expect(p.values["wrap"] == 0)
        #expect(p.values["mv_x"] == 12)
        #expect(p.values["zoom"] == 1)  // default
        #expect(p.frameCode == "a = 1;\nb = 2;")
        #expect(p.initCode == "q1 = 3;")
        #expect(p.pixelCode == "zoom = zoom + rad*0.1;")
        #expect(p.waves[1].isEnabled && p.waves[1].values["spectrum"] == 1 && p.waves[1].values["samples"] == 512)
        #expect(p.waves[1].pointCode == "x = sample;")
        #expect(!p.waves[0].isEnabled)
        #expect(p.shapes[3].values["num_inst"] == 4)
        #expect(p.shapes[3].frameCode == "ang = instance;")
        #expect(p.warp == "shader_body {\n  ret = tex2D(sampler_main, uv).xyz;\n}")
        #expect(p.comp.isEmpty)
    }

    @Test func numbersLikeParseFloat() {
        #expect(PresetFile.number("1.5f") == 1.5)
        #expect(PresetFile.number(" -2 ") == -2)
        #expect(PresetFile.number("x") == nil)
    }

    @Test func bundledPresetsParse() throws {
        let folder = try #require(MilkDropResources.presets)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "milk" }
        var shaders = 0, code = 0
        for file in files {
            let p = try PresetFile.load(file)
            if !p.warp.isEmpty || !p.comp.isEmpty { shaders += 1 }
            if !p.frameCode.isEmpty || !p.pixelCode.isEmpty { code += 1 }
            #expect(p.waves.count == 4 && p.shapes.count == 4)
            if !p.warp.isEmpty { #expect(p.warp.contains("shader_body"), "\(p.name)") }
        }
        #expect(shaders > 200 && code > 400)
    }
}
