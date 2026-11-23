import Metal

/// MSL of the passes that are the same for every preset, compiled once at run time (`swift build` does not compile
/// `.metal` files). Offscreen passes flip clip y, so targets keep GL's row order (see `Targets`).
enum FixedShaders {
    static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadOut { float4 position [[position]]; float2 uv; };

    /// A full-target quad as a 4-vertex strip; `uv` as in GL, 0 at the bottom.
    vertex QuadOut md_quad(uint id [[vertex_id]]) {
        float2 p = float2(id & 1 ? 1 : -1, id & 2 ? 1 : -1);
        QuadOut out;
        out.position = float4(p.x, -p.y, 0, 1);
        out.uv = p * 0.5 + 0.5;
        return out;
    }

    /// Copies a target into one of another size (window resize).
    fragment float4 md_copy(QuadOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return t.sample(s, in.uv);
    }
    """

    static func library(device: MTLDevice, extra: [String]) throws -> MTLLibrary {
        try device.makeLibrary(source: ([common, Blur.source, TitleText.source, GeometryPipelines.source] + extra).joined(separator: "\n"), options: nil)
    }
}
