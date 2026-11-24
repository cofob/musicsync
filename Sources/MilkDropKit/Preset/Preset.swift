/// A MilkDrop preset as its `.milk` file gives it: start values, equation code and shader code.
public struct Preset: Sendable {
    public var name: String
    /// 2 for MilkDrop 2 presets (`MILKDROP_PRESET_VERSION=201` or later), else 1.
    public var version: Int
    /// Start values by their equation names (`decay`, `zoom`, `wave_mode` …), with the defaults for missing keys.
    public var values: [String: Double]
    public var initCode = "", frameCode = "", pixelCode = ""
    public var waves: [Wave] = []
    public var shapes: [Shape] = []
    /// HLSL of the warp and comp shaders, or empty for the default shader.
    public var warp = "", comp = ""
    /// SHA-256 of the file (hex), which names its compiled shaders in the preset cache; empty when not from a file.
    public var sourceHash = ""

    public struct Wave: Sendable {
        public var values: [String: Double]
        public var initCode = "", frameCode = "", pointCode = ""
        public var isEnabled: Bool { (values["enabled"] ?? 0) != 0 }
    }

    public struct Shape: Sendable {
        public var values: [String: Double]
        public var initCode = "", frameCode = ""
        public var isEnabled: Bool { (values["enabled"] ?? 0) != 0 }
    }
}
