/// Translates MilkDrop 2 preset shaders (HLSL ps_2_0/ps_3_0) to Metal Shading Language.
public enum HLSLTranslator {
    /// `hlsl` is the text of the `warp_N` or `comp_N` lines joined with "\n": global code, then `shader_body { ... }`.
    public static func translate(_ hlsl: String, stage: ShaderStage) throws -> TranslatedShader {
        try translate(hlsl, allowInternal: false)
    }

    /// For presets without a shader (and as a fallback): butterchurn's default warp; as comp, MilkDrop 2's
    /// `ShowToUser_NoShaders`, which draws presets without a comp shader by fixed-function passes into the 8-bit
    /// back buffer: echo layers added `gammaAdj` times (at least once each with echo), then brighten, darken,
    /// solarize and invert as D3D blends of the clamped picture.
    public static func defaultShader(_ stage: ShaderStage) -> TranslatedShader {
        // The default sources are fixed and tested, so they always translate.
        try! translate(stage == .warp ? defaultWarp : defaultComp, allowInternal: true)
    }

    private static func translate(_ hlsl: String, allowInternal: Bool) throws -> TranslatedShader {
        let generator = MSLGenerator(allowInternal: allowInternal)
        let source = try generator.generate(try HLSLParser.parse(hlsl))
        return TranslatedShader(source: source, userTextures: generator.userTextures, blurLevel: generator.blurLevel)
    }

    static let defaultWarp = "shader_body { ret = tex2D(sampler_main, uv).rgb * decay; }"

    static let defaultComp = """
    shader_body {
        float orient_horiz = fmod(echo_orientation, 2.0);
        float orient_x = (orient_horiz != 0.0) ? -1.0 : 1.0;
        float orient_y = (echo_orientation >= 2.0) ? -1.0 : 1.0;
        float2 uv_echo = ((uv - 0.5) * (1.0 / echo_zoom) * float2(orient_x, orient_y)) + 0.5;
        ret = lerp(tex2D(sampler_main, uv).rgb, tex2D(sampler_main, uv_echo).rgb, echo_alpha);
        ret *= (echo_alpha > 0.001) ? max(gammaAdj, 1.0) : gammaAdj;
        if (fShader > 0.001) ret *= (1.0 - fShader) + (fShader * hue_shader);
        ret = saturate(ret);
        if (brighten != 0) ret = 1.0 - (1.0 - ret) * (1.0 - ret);
        if (darken != 0) ret = ret * ret;
        if (solarize != 0) ret = ret * (1.0 - ret) * 2.0;
        if (invert != 0) ret = 1.0 - ret;
    }
    """
}
