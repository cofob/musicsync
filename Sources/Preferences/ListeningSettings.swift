import Foundation

/// Settings > Library: what the app does with plays.
public struct ListeningSettings: StoredSettings {
    /// Where play counts for Your Stats and the mixes come from.
    public enum PlaysSource: String, Codable, CaseIterable, Sendable {
        /// The local history, with the server's counts where it has none.
        case history
        /// Only the server's play counts.
        case server
    }

    /// Sends played songs to the server (scrobbles), which also counts them there.
    public var scrobble = true
    public var playsSource = PlaysSource.history

    public static let defaultsKey = "listeningSettings"

    public init() {}

    public var usesHistory: Bool { playsSource == .history }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ListeningSettings()
        scrobble = c.value(.scrobble, or: d.scrobble)
        playsSource = c.value(.playsSource, or: d.playsSource)
    }
}
