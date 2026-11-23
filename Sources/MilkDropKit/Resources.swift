import Foundation

/// Bundled presets and textures. Not `Bundle.module`: its accessor looks next to the `.app`, not in `Contents/Resources`,
/// where `scripts/bundle.sh` puts the SwiftPM bundles.
public enum MilkDropResources {
    static let bundle: Bundle? = {
        let name = "MusicSync_MilkDropKit"
        let url = Bundle.main.url(forResource: name, withExtension: "bundle")
            ?? Bundle.main.bundleURL.appendingPathComponent("\(name).bundle")
        return Bundle(url: url) ?? Bundle(url: Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("\(name).bundle"))
    }()

    private final class Marker {}

    /// Folder of the MilkDrop 2 presets that ship with the app.
    public static var presets: URL? { folder("Presets") }
    /// Folder of the textures that presets name in their shaders (`sampler_clouds` and others).
    public static var textures: URL? { folder("Textures") }

    private static func folder(_ name: String) -> URL? {
        bundle?.resourceURL?.appendingPathComponent(name, isDirectory: true)
    }
}
