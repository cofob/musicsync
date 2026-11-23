/// Fixed MSL parts of every translated shader and the HLSL names of the uniforms.
enum MSLPreamble {
    static let maxUserTextures = 16

    static let rotationNames = ["s", "d", "f", "vf", "uf", "rand"].flatMap { group in (1...4).map { "rot_\(group)\($0)" } }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct MDVertex { packed_float2 position; packed_float2 uv; packed_float2 uv_orig; float rad; float ang; packed_float4 color; };
    struct MDVaryings { float4 position [[position]]; float2 uv; float2 uv_orig; float rad; float ang; float4 color; };

    struct ShaderUniforms {
        float4 texsize;      // width, height, 1/width, 1/height
        float4 aspect;       // aspectx, aspecty, 1/aspectx, 1/aspecty
        float4 timing;       // time, fps, frame, progress
        float4 audio;        // bass, mid, treb, vol
        float4 audio_att;    // bass_att, mid_att, treb_att, vol_att
        float4 _qa, _qb, _qc, _qd, _qe, _qf, _qg, _qh;
        float4 rand_preset, rand_frame;
        float4 roam_cos, roam_sin, slow_roam_cos, slow_roam_sin;
        float4 blur_min, blur_max, blur_scale, blur_bias; // blur1, blur2, blur3 in x, y, z
        float4 texsize_noise_lq, texsize_noise_mq, texsize_noise_hq, texsize_noise_lq_lite, texsize_noisevol_lq, texsize_noisevol_hq;
        float4 comp_a;       // decay, gamma_adj, echo_zoom, echo_alpha
        float4 comp_b;       // echo_orient, fshader, 0, 0
        float4 comp_flags;   // invert, brighten, darken, solarize
        float4x4 rot[24];    // rot_s1..4, rot_d1..4, rot_f1..4, rot_vf1..4, rot_uf1..4, rot_rand1..4
        float4 texsize_user[\(maxUserTextures)];
    };

    constexpr sampler md_fw(filter::linear, mip_filter::linear, address::repeat);
    constexpr sampler md_fc(filter::linear, mip_filter::linear, address::clamp_to_edge);
    constexpr sampler md_pw(filter::nearest, mip_filter::nearest, address::repeat);
    constexpr sampler md_pc(filter::nearest, mip_filter::nearest, address::clamp_to_edge);

    inline float4x3 md_rot(float4x4 m) { return float4x3(m[0].xyz, m[1].xyz, m[2].xyz, m[3].xyz); }
    template <int C, int R> inline matrix<float, C, R> md_mul_cw(matrix<float, C, R> a, matrix<float, C, R> b) { for (int i = 0; i < C; i++) a[i] *= b[i]; return a; }
    template <int C, int R> inline matrix<float, C, R> md_div_cw(matrix<float, C, R> a, matrix<float, C, R> b) { for (int i = 0; i < C; i++) a[i] /= b[i]; return a; }

    vertex MDVaryings md_vertex(device const MDVertex* md_v [[buffer(0)]], uint md_vid [[vertex_id]]) {
        MDVertex v = md_v[md_vid];
        MDVaryings o;
        o.position = float4(float2(v.position), 0.0, 1.0);
        o.uv = float2(v.uv);
        o.uv_orig = float2(v.uv_orig);
        o.rad = v.rad;
        o.ang = v.ang;
        o.color = float4(v.color);
        return o;
    }

    """

    /// Built-in textures in fragment binding order, with their default sampler.
    static let textures: [(name: String, is3D: Bool, sampler: String)] = [
        ("main", false, "_c.md_smain"), ("blur1", false, "md_fc"), ("blur2", false, "md_fc"), ("blur3", false, "md_fc"),
        ("noise_lq", false, "md_fw"), ("noise_mq", false, "md_fw"), ("noise_hq", false, "md_fw"),
        ("noisevol_lq", true, "md_fw"), ("noisevol_hq", true, "md_fw"),
    ]

    /// HLSL uniform name → type and member path in `ShaderUniforms`.
    static let uniforms: [String: (HType, String)] = {
        let f4 = HType.vector(.float, 4)
        var u: [String: (HType, String)] = [:]
        for name in ["texsize", "aspect", "rand_preset", "rand_frame", "roam_cos", "roam_sin", "slow_roam_cos", "slow_roam_sin",
                     "texsize_noise_lq", "texsize_noise_mq", "texsize_noise_hq", "texsize_noise_lq_lite", "texsize_noisevol_lq", "texsize_noisevol_hq"] {
            u[name] = (f4, name)
        }
        let groups = [
            ("timing", ["time", "fps", "frame", "progress"]), ("audio", ["bass", "mid", "treb", "vol"]),
            ("audio_att", ["bass_att", "mid_att", "treb_att", "vol_att"]), ("blur_min", ["blur1_min", "blur2_min", "blur3_min"]),
            ("blur_max", ["blur1_max", "blur2_max", "blur3_max"]), ("blur_scale", ["scale1", "scale2", "scale3"]),
            ("blur_bias", ["bias1", "bias2", "bias3"]), ("comp_a", ["decay"]),
        ]
        for (field, names) in groups { addScalars(&u, field, names) }
        for (i, letter) in "abcdefgh".enumerated() {
            u["_q\(letter)"] = (f4, "_q\(letter)")
            addScalars(&u, "_q\(letter)", (1...4).map { "q\(i * 4 + $0)" })
        }
        for (i, name) in rotationNames.enumerated() { u[name] = (.matrix(.float, rows: 4, cols: 3), "rot[\(i)]") }
        return u
    }()

    /// Values only the default comp shader sees.
    static let internalUniforms: [String: (HType, String)] = {
        var u: [String: (HType, String)] = [:]
        addScalars(&u, "comp_a", ["", "gammaAdj", "echo_zoom", "echo_alpha"])
        addScalars(&u, "comp_b", ["echo_orientation", "fShader"])
        addScalars(&u, "comp_flags", ["invert", "brighten", "darken", "solarize"])
        return u
    }()

    private static func addScalars(_ u: inout [String: (HType, String)], _ field: String, _ names: [String]) {
        for (name, c) in zip(names, "xyzw") where !name.isEmpty { u[name] = (.float, "\(field).\(c)") }
    }

    /// Names a user identifier cannot keep in MSL.
    static let reserved: Set<String> = [
        "auto", "break", "case", "char", "class", "const_cast", "constant", "constexpr", "decltype", "default", "delete",
        "device", "dynamic_cast", "enum", "explicit", "export", "extern", "fragment", "friend", "goto", "kernel", "long",
        "mutable", "namespace", "new", "noexcept", "nullptr", "operator", "private", "protected", "public", "register",
        "reinterpret_cast", "short", "signed", "sizeof", "static_assert", "static_cast", "switch", "template", "this",
        "thread", "threadgroup", "throw", "try", "catch", "typeid", "typename", "union", "unsigned", "using", "vertex",
        "virtual", "wchar_t", "metal", "uchar", "ushort", "ulong", "size_t", "ptrdiff_t", "vec", "matrix", "array",
        "sampler", "texture2d", "texture3d", "mix", "fract", "fmod", "dfdx", "dfdy", "select", "fma", "level", "bias",
        "gradient2d", "discard_fragment", "as_type", "half", "packed_float2", "packed_float3", "packed_float4", "assert",
        "and", "or", "not", "xor", "bitand", "bitor", "compl", "and_eq", "or_eq", "xor_eq", "not_eq", "alignas", "alignof",
        "char16_t", "char32_t", "thread_local", "typedef", "visible", "stage_in", "filter", "address", "coord", "access",
        "min_filter", "mag_filter", "mip_filter", "function", "int8_t", "int16_t", "int32_t", "int64_t",
    ]
}
