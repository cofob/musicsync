import Foundation

/// Settings > Advanced.
public struct AdvancedSettings: StoredSettings {
    /// Seconds a server request may wait for data.
    public var requestTimeout = 30
    /// Disk size of the cover cache in MB; 0 = no limit.
    public var coverCacheMB = 500

    public static let defaultsKey = "advancedSettings"
    public static let timeouts = [15, 30, 60, 120]
    public static let coverCacheSizes = [100, 250, 500, 1000, 2000, 0]

    public init() {}

    public var coverCacheBytes: Int64? { coverCacheMB > 0 ? Int64(coverCacheMB) * 1_000_000 : nil }

    /// A session for server requests that waits at most `requestTimeout` for data.
    public func session() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(max(5, requestTimeout))
        return URLSession(configuration: config)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AdvancedSettings()
        requestTimeout = c.value(.requestTimeout, or: d.requestTimeout)
        coverCacheMB = c.value(.coverCacheMB, or: d.coverCacheMB)
    }
}
