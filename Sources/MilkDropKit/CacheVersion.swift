/// Versions of the preset cache (`PresetCDN`, `scripts/preset-cache.sh`). The app takes only sets made for its own
/// `renderer`; with none, it compiles and measures presets itself.
public enum PresetCacheFormat {
    /// Raised when the layout of the index or the manifest changes.
    public static let format = 1
    /// Raised when what a preset gives changes: the shader translator, the renderer, the demo track or the measures.
    public static let renderer = 1
}
