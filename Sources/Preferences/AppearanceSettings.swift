import Foundation

/// Settings > Appearance.
public struct AppearanceSettings: StoredSettings {
    public enum Accent: String, Codable, CaseIterable, Sendable {
        case red, pink, orange, purple, blue, graphite

        /// sRGB components; red is the Apple Music red.
        public var rgb: (red: Double, green: Double, blue: Double) {
            switch self {
            case .red: (0.98, 0.14, 0.24)
            case .pink: (0.96, 0.27, 0.56)
            case .orange: (1.0, 0.58, 0.0)
            case .purple: (0.69, 0.32, 0.87)
            case .blue: (0.0, 0.48, 1.0)
            case .graphite: (0.56, 0.56, 0.58)
            }
        }
    }

    /// Cover size in album grids.
    public enum GridDensity: String, Codable, CaseIterable, Sendable {
        case small, medium, large

        /// Smallest and largest card width in points.
        public var cardWidth: ClosedRange<Double> {
            switch self {
            case .small: 120...170
            case .medium: 160...240
            case .large: 230...330
            }
        }
    }

    public enum NowPlayingBackground: String, Codable, CaseIterable, Sendable {
        /// Colors taken from the cover.
        case artwork
        case plain
    }

    /// Page the main window opens with.
    public enum StartPage: String, Codable, CaseIterable, Sendable {
        case home, albums, songs, last

        /// Sidebar key to open; `last` falls back to Home before any page was opened.
        public func key(last: String?) -> String {
            self == .last ? last ?? StartPage.home.rawValue : rawValue
        }
    }

    /// Optional details on the right of song rows.
    public enum SongColumn: String, Codable, CaseIterable, Sendable {
        case rating, plays, format

        /// Text of the chosen columns, in a fixed order; nil when there is nothing to show.
        public static func detail(_ columns: Set<SongColumn>, rating: Int?, plays: Int?, suffix: String?, bitRate: Int?) -> String? {
            var parts: [String] = []
            if columns.contains(.rating), let rating, rating > 0 { parts.append(String(repeating: "★", count: min(rating, 5))) }
            if columns.contains(.plays), let plays, plays > 0 { parts.append(plays == 1 ? "1 play" : "\(plays) plays") }
            if columns.contains(.format), let suffix, !suffix.isEmpty {
                parts.append([suffix.uppercased(), bitRate.flatMap { $0 > 0 ? "\($0) kbps" : nil }].compactMap { $0 }.joined(separator: " "))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    public var accent = Accent.red
    public var density = GridDensity.medium
    /// Keys of sidebar rows the user turned off (Edit Sidebar).
    public var hiddenSidebarItems: Set<String> = []
    public var nowPlayingBackground = NowPlayingBackground.artwork
    public var startPage = StartPage.home
    public var songColumns: Set<SongColumn> = []

    public static let defaultsKey = "appearanceSettings"

    public init() {}

    public func shows(_ sidebarKey: String) -> Bool { !hiddenSidebarItems.contains(sidebarKey) }

    public mutating func setShown(_ sidebarKey: String, _ shown: Bool) {
        if shown { hiddenSidebarItems.remove(sidebarKey) } else { hiddenSidebarItems.insert(sidebarKey) }
    }

    /// Missing or unknown values keep their defaults, so settings of an older or newer version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        accent = c.value(.accent, or: d.accent)
        density = c.value(.density, or: d.density)
        hiddenSidebarItems = c.value(.hiddenSidebarItems, or: d.hiddenSidebarItems)
        nowPlayingBackground = c.value(.nowPlayingBackground, or: d.nowPlayingBackground)
        startPage = c.value(.startPage, or: d.startPage)
        songColumns = Set(c.value(.songColumns, or: [String]()).compactMap(SongColumn.init))
    }
}
