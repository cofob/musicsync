/// Which MilkDrop pixel shader a source is: the warp (feedback) pass or the composite (display) pass.
public enum ShaderStage: Sendable { case warp, comp }

/// A preset texture a shader samples, as named by its `sampler_<prefix_>name` declaration.
public struct UserTexture: Codable, Sendable, Hashable {
    /// Texture name without the `sampler_` and `fw_`/`fc_`/`pw_`/`pc_` prefixes (`clouds`, `rand00_smalltiled`).
    public var name: String
    /// Repeat (true) or clamp to edge (false).
    public var wrap: Bool
    /// Bilinear (true) or nearest (false) filtering.
    public var filter: Bool

    public init(name: String, wrap: Bool, filter: Bool) {
        self.name = name
        self.wrap = wrap
        self.filter = filter
    }
}

/// MSL source made from one preset shader, plus what the renderer must bind for it.
public struct TranslatedShader: Sendable {
    /// Complete MSL: preamble, globals, vertex function `md_vertex` and fragment function `md_fragment`.
    public var source: String
    /// Bound at texture(9), (10), ... in this order.
    public var userTextures: [UserTexture]
    /// 0...3: highest blur texture the shader samples.
    public var blurLevel: Int

    /// What the renderer binds, without the source.
    public var info: ShaderInfo { ShaderInfo(textures: userTextures, blur: blurLevel) }
}

/// What the renderer binds for a compiled shader: kept with it in the preset cache, so the shader is not translated again.
public struct ShaderInfo: Codable, Hashable, Sendable {
    public var textures: [UserTexture]
    public var blur: Int

    public init(textures: [UserTexture], blur: Int) { (self.textures, self.blur) = (textures, blur) }
}

/// A shader the translator cannot handle, with the source line when known.
public struct HLSLError: Error, CustomStringConvertible {
    public var message: String
    public var line: Int

    init(_ message: String, line: Int = 0) {
        self.message = message
        self.line = line
    }

    public var description: String { line > 0 ? "line \(line): \(message)" : message }
}
