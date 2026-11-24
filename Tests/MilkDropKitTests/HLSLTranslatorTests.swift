import Foundation
import Metal
@testable import MilkDropKit
import Testing

/// Translates a shader, checks that Metal compiles it (when there is a device) and returns it.
private func translated(_ body: String, globals: String = "", stage: ShaderStage = .warp) throws -> TranslatedShader {
    let shader = try HLSLTranslator.translate(globals + "\nshader_body {\n" + body + "\n}", stage: stage)
    if let device = MTLCreateSystemDefaultDevice(), let error = metalError(shader.source, device) {
        Issue.record("Metal: \(error)\n\(shader.source)")
    }
    return shader
}

private func msl(_ body: String, globals: String = "") throws -> String {
    try translated(body, globals: globals).source
}

@Suite struct HLSLTranslatorTests {
    @Test func implicitTruncationAndSplat() throws {
        let code = try msl("float3 v = 0; float2 a = tex2D(sampler_main, uv); float3 c = tex2D(sampler_main, a) - 0.5; ret = v + a.x + c;")
        #expect(code.contains("float3 v = float3(0.0);"))
        #expect(code.contains("float2 a = _c.md_main.sample(_c.md_smain, uv).xy;"))
        #expect(code.contains("float3 c = (_c.md_main.sample(_c.md_smain, a) - 0.5).xyz;"))
    }

    @Test func mixedVectorSizesTruncateToTheSmaller() throws {
        let code = try msl("float4 a = 1; float2 b = 2; ret.xy = a * b; ret = ret + a;")
        #expect(code.contains("ret.xy = (a.xy * b);"))
        #expect(code.contains("ret = (ret + a.xyz);"))
    }

    @Test func scalarSwizzle() throws {
        let code = try msl("float x = 0.5; ret = x.xxx; ret.x = x.x;")
        #expect(code.contains("ret = float3(x);"))
        #expect(code.contains("ret.x = x;"))
    }

    @Test func mulSwapsOperandsAndKeepsConstructors() throws {
        let code = try msl("float2 p = mul(uv, float2x2(1, 2, 3, 4)); float2 q = mul(float2x2(_qa), p); ret = float3(p + q, 0);")
        #expect(code.contains("float2 p = (float2x2(1.0, 2.0, 3.0, 4.0) * uv);"))
        #expect(code.contains("(p * float2x2(_c.md_u._qa.x, _c.md_u._qa.y, _c.md_u._qa.z, _c.md_u._qa.w))"))
    }

    @Test func matrixInitializerListAndComponentwiseOperators() throws {
        let code = try msl("float2x2 r = { cos(time), sin(time), -sin(time), cos(time) }; r = r - rad * 0.01; ret.xy = mul(uv - 0.5, -r);")
        #expect(code.contains("float2x2 r = float2x2(cos("))
        #expect(code.contains("(r * -1.0)"))
    }

    @Test func floatModuloIsFmod() throws {
        let code = try msl("int i = 7; int j = i % 2; float f = time % 2; int2 k = (texsize.xy * uv) % 2; ret = f + j + k.x;")
        #expect(code.contains("int j = (i % 2);"))
        #expect(code.contains("float f = fmod(_c.md_u.timing.x, 2.0);"))
        #expect(code.contains("int2 k = int2(fmod((_c.md_u.texsize.xy * uv), float2(2.0)));"))
    }

    @Test func intrinsicNames() throws {
        let code = try msl("ret = lerp(frac(uv.x), saturate(rad), 0.5) + atan2(uv.y, uv.x) + rsqrt(2) + ddx(uv.x) + ddy(uv.y) + pow(rad, 2);")
        for name in ["mix(", "fract(", "saturate(", "atan2(", "rsqrt(2.0)", "dfdx(", "dfdy(", "pow(rad, 2.0)"] { #expect(code.contains(name)) }
    }

    @Test func lerpSplatsScalarArguments() throws {
        let code = try msl("ret = lerp(ret, 2, GetPixel(uv).x * 0.4);")
        #expect(code.contains("mix(ret, float3(2.0), float3("))
    }

    @Test func textureLookupsAndHelpers() throws {
        let shader = try translated("""
        float3 a = GetMain(uv) + GetPixel(uv) + GetBlur1(uv) + GetBlur2(uv);
        float n = tex2D(sampler_noise_lq, uv).x + tex2D(sampler_pw_noise_lq, uv).x + tex3D(sampler_noisevol_hq, float3(uv, time)).x;
        float b = tex2d(sampler_fc_main, uv).x + tex2D(sampler_pw_main, uv).y + lum(a);
        ret = a * n * b * M_PI * M_PI_2 * M_INV_PI_2;
        """)
        #expect(shader.blurLevel == 2)
        #expect(shader.source.contains("_c.md_blur2.sample(md_fc, uv).xyz * _c.md_u.blur_scale.y) + _c.md_u.blur_bias.y"))
        #expect(shader.source.contains("_c.md_noise_lq.sample(md_pw, uv)"))
        #expect(shader.source.contains("_c.md_noisevol_hq.sample(md_fw, float3(uv, _c.md_u.timing.x))"))
        #expect(shader.source.contains("_c.md_main.sample(md_fc, uv)"))
        #expect(shader.source.contains("dot(a, float3(0.32, 0.49, 0.29))"))
        #expect(shader.source.contains("3.14159265359"))
    }

    @Test func userTexturesAndTheirSizes() throws {
        let shader = try translated(
            "ret = tex2D(sampler_fc_clouds, uv).xyz * texsize_clouds.x + tex2D(sampler_worms, uv).xyz + tex2D(sampler_pc_rand00_smalltiled, uv).xyz;",
            globals: "sampler sampler_fc_clouds; sampler sampler_worms; sampler2D sampler_pc_rand00_smalltiled; sampler sampler_unused; float4 texsize_clouds;")
        #expect(shader.userTextures == [
            UserTexture(name: "clouds", wrap: false, filter: true), UserTexture(name: "worms", wrap: true, filter: true),
            UserTexture(name: "rand00_smalltiled", wrap: false, filter: false),
        ])
        #expect(shader.source.contains("_c.md_user0.sample(md_fc, uv)"))
        #expect(shader.source.contains("_c.md_u.texsize_user[0].x"))
        #expect(shader.source.contains("texture2d<float> md_user2 [[texture(11)]]"))
    }

    @Test func userFunctionsSeeUniformsTexturesAndGlobals() throws {
        let code = try msl("ret = f(uv); ret += g();", globals: """
        sampler sampler_lichen;
        float3 shared_value;
        static const float width = 5;
        static float3 sxy = float3(q4, q5, q6);
        float3 f(float2 uv) { shared_value = sxy * width; return tex2D(sampler_lichen, uv).xyz * time + GetBlur1(uv); }
        float3 g() { return shared_value; }
        """)
        #expect(code.contains("float3 fn_f(thread MDContext& _c, float2 uv)"))
        #expect(code.contains("_c.shared_value = (_c.sxy * _c.width);"))
        #expect(code.contains("_c.sxy = float3(_c.md_u._qa.w, _c.md_u._qb.x, _c.md_u._qb.y);"))
        #expect(code.contains("ret = fn_f(_c, uv);"))
    }

    @Test func outParameters() throws {
        let code = try msl("float a; float b; split(rad, a, b); ret = a + b;", globals: "void split(float x, out float s, inout float c) { s = sin(x); c = cos(x); }")
        #expect(code.contains("void fn_split(thread MDContext& _c, float x, thread float& s, thread float& c)"))
    }

    @Test func mslKeywordsAreRenamed() throws {
        let code = try msl("float kernel = 1; float vertex = 2; float md_x = 3; float mix = 4; ret = kernel + vertex + md_x + mix;")
        for name in ["kernel_", "vertex_", "md_x_", "mix_"] { #expect(code.contains("float \(name) = ")) }
    }

    @Test func typesAndControlFlow() throws {
        let code = try msl("""
        half3 h = 1; bool on = rad > 0.5; int n = 0; int mask = (uv.y > 0);
        float1 one = 1; float4 c = (float4)0.5; float2 cast = (float2)c;
        for (int i = 0; i < 4; i++) { n += 1; if (n > 2) break; }
        while (n <= 5) { n++; }
        do { n--; } while (n > 0);
        ret = on ? h : float3(0, 0, 1);
        ret *= mask * one + cast.x;
        ret = uv.x > 0.5 ? 1 : 0;
        """)
        #expect(code.contains("float3 h = float3(1.0);"))
        #expect(code.contains("int mask = int((uv.y > 0.0));"))
        #expect(code.contains("for (int i = 0; (i < 4); i++)"))
        #expect(code.contains("ret = float3(float(((uv.x > 0.5) ? 1 : 0)));"))
    }

    @Test func intCompoundAssignmentWithFloat() throws {
        #expect(try msl("int n = 3; n *= 0.5; ret = n;").contains("n = int((float(n) * 0.5));"))
    }

    @Test func preprocessor() throws {
        let code = try msl("ret = MyGet(uv) * SCALE;", globals: """
        #define MyGet GetPixel //GetBlur1
        #if 0
        #define SCALE 3
        #else
        #define SCALE 2
        #endif
        /* block
           comment */
        """)
        #expect(code.contains("_c.md_main.sample(_c.md_smain, uv).xyz * 2.0"))
    }

    @Test func writableUniforms() throws {
        let code = try msl("q25 = 2; rand_preset.x += 1; ret = q25 * rand_preset.xyz;")
        #expect(code.contains("_c.q25 = _c.md_u._qg.x;"))
        #expect(code.contains("_c.q25 = 2.0;"))
    }

    @Test func rotationMatrices() throws {
        #expect(try msl("ret = mul(float4(uv, 0, 1), rot_s1) + mul(float4(ret, 1), rot_rand4);").contains("(md_rot(_c.md_u.rot[0]) * float4(uv, 0.0, 1.0))"))
    }

    @Test func arrayInitializers() throws {
        let code = try msl("float2 o[2] = { float2(1, 0), float2(0, 1) }; ret.xy = samples[1].xy + o[1];", globals: "const float4 samples[2] = { -1.0, 0.0, 0, 0.25, 1.0, 0.0, 0, 0.25 };")
        #expect(code.contains("_c.samples[1] = float4(1.0, 0.0, 0.0, 0.25);"))
        #expect(code.contains("float2 o[2] = {float2(1.0, 0.0), float2(0.0, 1.0)};"))
    }

    @Test func compInputsAndAlpha() throws {
        let code = try translated("ret = hue_shader * rad * ang + float3(uv_orig, 0);", stage: .comp).source
        #expect(code.contains("float3 hue_shader = md_in.color.rgb;"))
        #expect(code.contains("return float4(ret, md_in.color.a);"))
    }

    @Test func matrixTimesIntLiteral() throws {
        #expect(try msl("float2x2 m = float2x2(texsize.z, 0, 0, texsize.w) * 4; ret.xy = mul(uv, m);").contains(" * 4.0)"))
    }

    @Test func variablesNamedLikeFunctionsAreRenamed() throws {
        let code = try msl("float3 max = max(ret, max(ret, 1)); float dot = dot(uv, uv); float2 pow = pow(uv, 2); ret = max * dot + pow.x;")
        for name in ["max_", "dot_", "pow_"] { #expect(code.contains("\(name) = ")) }
    }

    @Test func samplerStateIsSkipped() throws {
        let shader = try translated("ret = tex2D(sampler_grad, uv).xyz;", globals: "sampler sampler_grad = sampler_state { AddressU = WRAP; AddressV = WRAP; };")
        #expect(shader.userTextures == [UserTexture(name: "grad", wrap: true, filter: true)])
    }

    @Test func modfSplitsTowardZero() throws {
        #expect(try msl("float i; float f = modf(rad * 3, i); ret = f + i;").contains("(i = trunc((rad * 3.0)), (rad * 3.0) - i)"))
    }

    @Test func errorsHaveLines() {
        #expect(throws: HLSLError.self) { try HLSLTranslator.translate("shader_body {\n ret = nothing;\n}", stage: .warp) }
        do {
            _ = try HLSLTranslator.translate("shader_body {\n ret = nothing;\n}", stage: .warp)
        } catch let error as HLSLError {
            #expect(error.line == 2)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(throws: HLSLError.self) { try HLSLTranslator.translate("float x;", stage: .warp) }
    }

    @Test func defaultShadersCompile() throws {
        let warp = HLSLTranslator.defaultShader(.warp)
        let comp = HLSLTranslator.defaultShader(.comp)
        #expect(warp.source.contains("_c.md_main.sample(_c.md_smain, uv).xyz * _c.md_u.comp_a.x"))
        #expect(comp.source.contains("_c.md_u.comp_a.z"))
        #expect(warp.userTextures.isEmpty && comp.blurLevel == 0)
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        #expect(metalError(warp.source, device) == nil)
        #expect(metalError(comp.source, device) == nil)
        // Users cannot reach the default comp's own values.
        #expect(throws: HLSLError.self) { try HLSLTranslator.translate("shader_body { ret = echo_zoom; }", stage: .comp) }
    }

    /// As D3D9: pow of a negative base uses its absolute value, so pictures do not go black on NaN.
    @Test func powTakesTheAbsoluteBase() throws {
        let shader = try HLSLTranslator.translate("shader_body { ret = pow(float3(-0.5, 2, 1), 2); }", stage: .comp)
        #expect(shader.source.contains("md_pow("))
    }
}
