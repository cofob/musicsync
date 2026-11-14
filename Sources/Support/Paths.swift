import Foundation

/// App-wide local directories. Created on first access.
public enum Paths {
    public static let appName = "MusicSync"
    /// Development only: `MUSICSYNC_DEMO=1` keeps all app files under `<tmp>/musicsync-demo`.
    public static let isDemo = ProcessInfo.processInfo.environment["MUSICSYNC_DEMO"] == "1"
    public static let demoDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-demo")

    public static var appSupport: URL { ensure(.applicationSupportDirectory) }
    public static var caches: URL { ensure(.cachesDirectory) }

    public static func appSupport(_ components: String...) -> URL { make(appSupport, components) }
    public static func caches(_ components: String...) -> URL { make(caches, components) }

    private static func ensure(_ dir: FileManager.SearchPathDirectory) -> URL {
        let base = isDemo ? demoDirectory.appendingPathComponent(dir == .cachesDirectory ? "Caches" : "Application Support")
                          : FileManager.default.urls(for: dir, in: .userDomainMask)[0].appendingPathComponent(appName)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func make(_ base: URL, _ components: [String]) -> URL {
        let url = components.reduce(base) { $0.appendingPathComponent($1) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public extension UserDefaults {
    /// The app settings; a separate suite in demo mode. `UserDefaults` is thread-safe.
    nonisolated(unsafe) static let app = Paths.isDemo ? UserDefaults(suiteName: "dev.cofob.musicsync.demo")! : .standard
}

public extension FileManager {
    /// Writes data to a temp file next to `url`, full-fsyncs it, then renames over `url`.
    func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".musicsync-tmp")
        try? removeItem(at: tmp)
        guard createFile(atPath: tmp.path, contents: data) else { throw CocoaError(.fileWriteUnknown) }
        let fd = open(tmp.path, O_RDWR)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        if fileExists(atPath: url.path) { _ = try replaceItemAt(url, withItemAt: tmp) } else { try moveItem(at: tmp, to: url) }
    }
}
