import Foundation

/// A smart download rule: a kind of song the app keeps offline on its own.
public enum SmartRule: String, CaseIterable, Codable, Sendable {
    /// Starred songs and the songs of starred albums.
    case favorites
    /// Today's "Made for You" mixes.
    case mixes
    /// The most played songs.
    case mostPlayed
    /// Albums added to the library in the last days.
    case recentAlbums
    /// Chosen playlists, kept in sync with the server.
    case playlists
}

/// Settings > Downloads > Smart Downloads. Part of `DownloadSettings`.
public struct SmartSettings: Codable, Equatable, Sendable {
    /// One rule: on or off, and the most it may keep.
    public struct Rule: Codable, Equatable, Sendable {
        public var isOn = false
        public var budgetGB = 2.0
        public init() {}
    }

    public var favorites = Rule()
    public var mixes = Rule()
    public var mostPlayed = Rule()
    public var recentAlbums = Rule()
    public var playlists = Rule()
    /// Songs of the most played rule.
    public var mostPlayedCount = 100
    /// Age limit of the recently added rule.
    public var recentDays = 30
    /// Playlists of the playlists rule.
    public var playlistIDs: [String] = []
    /// The most all rules together may keep.
    public var budgetGB = 10.0
    /// Only on Wi-Fi or Ethernet that is not marked expensive or constrained (Low Data Mode).
    public var unmeteredOnly = true
    public var powerOnly = false
    /// Waits while the app streams, so downloads do not slow playback down.
    public var pauseWhileStreaming = true

    public init() {}

    public subscript(rule: SmartRule) -> Rule {
        get {
            switch rule {
            case .favorites: favorites
            case .mixes: mixes
            case .mostPlayed: mostPlayed
            case .recentAlbums: recentAlbums
            case .playlists: playlists
            }
        }
        set {
            switch rule {
            case .favorites: favorites = newValue
            case .mixes: mixes = newValue
            case .mostPlayed: mostPlayed = newValue
            case .recentAlbums: recentAlbums = newValue
            case .playlists: playlists = newValue
            }
        }
    }

    public var isOn: Bool { SmartRule.allCases.contains { self[$0].isOn } }

    static func bytes(_ gb: Double) -> Int64 { Int64(max(0, gb) * 1_000_000_000) }
}

/// What smart downloads depend on right now; the app reads it from the system.
public struct SmartConditions: Equatable, Sendable {
    public enum Network: Sendable, Equatable {
        case none
        /// Wi-Fi or Ethernet, not expensive or constrained.
        case unmetered
        /// Cellular (e.g. a phone hotspot), or a network marked expensive or constrained.
        case metered
    }

    /// Why smart downloads wait.
    public enum Wait: Sendable, Equatable {
        case network, power, streaming
    }

    public var network: Network
    public var onPower: Bool
    public var streaming: Bool

    public init(network: Network = .unmetered, onPower: Bool = true, streaming: Bool = false) {
        self.network = network
        self.onPower = onPower
        self.streaming = streaming
    }

    /// Nil when smart downloads may run.
    public func wait(for settings: SmartSettings) -> Wait? {
        if network == .none || (settings.unmeteredOnly && network != .unmetered) { return .network }
        if settings.powerOnly && !onPower { return .power }
        if settings.pauseWhileStreaming && streaming { return .streaming }
        return nil
    }
}
