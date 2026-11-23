import Foundation

/// Settings > Appearance.
public struct AppearanceSettings: StoredSettings {
    public enum Accent: String, Codable, CaseIterable, Sendable {
        case red, pink, orange, purple, blue, green, graphite
        /// Taken from the cover of the current song; red without one.
        case album

        public typealias RGB = (red: Double, green: Double, blue: Double)

        /// sRGB components; red is the default accent.
        public var rgb: RGB {
            switch self {
            case .red, .album: (0.98, 0.14, 0.24)
            case .pink: (0.96, 0.27, 0.56)
            case .orange: (1.0, 0.58, 0.0)
            case .purple: (0.69, 0.32, 0.87)
            case .blue: (0.0, 0.48, 1.0)
            case .green: (0.2, 0.78, 0.35)
            case .graphite: (0.56, 0.56, 0.58)
            }
        }

        /// The most colorful of the cover `samples`, made bright and strong enough to read on light and dark
        /// backgrounds; nil for a gray cover.
        public static func vivid(_ samples: [RGB]) -> RGB? {
            let hsb = samples.map(Self.hsb).filter { $0.saturation > 0.2 && $0.brightness > 0.15 }
            guard let best = hsb.max(by: { $0.saturation * $0.brightness < $1.saturation * $1.brightness }) else { return nil }
            return Self.rgb(hue: best.hue, saturation: max(best.saturation, 0.55), brightness: min(max(best.brightness, 0.7), 0.9))
        }

        private static func hsb(_ c: RGB) -> (hue: Double, saturation: Double, brightness: Double) {
            let high = max(c.red, c.green, c.blue), delta = high - min(c.red, c.green, c.blue)
            guard delta > 0 else { return (0, 0, high) }
            let sector = high == c.red ? (c.green - c.blue) / delta : high == c.green ? (c.blue - c.red) / delta + 2 : (c.red - c.green) / delta + 4
            return ((sector / 6 + 1).truncatingRemainder(dividingBy: 1), delta / high, high)
        }

        private static func rgb(hue: Double, saturation: Double, brightness: Double) -> RGB {
            func channel(_ n: Double) -> Double {
                let k = (n + hue * 6).truncatingRemainder(dividingBy: 6)
                return brightness - brightness * saturation * max(0, min(k, 4 - k, 1))
            }
            return (channel(5), channel(3), channel(1))
        }
    }

    /// Row height of song lists and the Songs table.
    public enum ListDensity: String, Codable, CaseIterable, Sendable {
        case comfortable, compact

        /// Height of a song list row, with or without a second line.
        public func rowHeight(twoLines: Bool) -> Double {
            switch self {
            case .comfortable: twoLines ? 54 : 42
            case .compact: twoLines ? 44 : 32
            }
        }

        public var tableRowHeight: Double { self == .compact ? 20 : 24 }
    }

    /// A column of the Songs table.
    public enum SongsTableColumn: String, Codable, CaseIterable, Sendable {
        case track, title, artist, album, time, plays, rating, star, genre, year, added, bitRate, size

        /// Shown before the user changes them, in this order.
        public static let defaults: [SongsTableColumn] = [.title, .time, .artist, .album, .genre, .star, .rating, .plays]
        /// Defaults of the iPod Songs table.
        public static let deviceDefaults: [SongsTableColumn] = [.title, .time, .artist, .album, .rating, .plays, .size]
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
        /// Colors taken from the cover that slowly move.
        case animated
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
    public var listDensity = ListDensity.comfortable
    /// Shown columns of the Songs table, in order; the title is always one of them.
    public private(set) var tableColumns = SongsTableColumn.defaults
    /// Shown columns of the iPod Songs table, in order.
    public private(set) var deviceTableColumns = SongsTableColumn.deviceDefaults
    /// Keys of sidebar rows the user turned off (Edit Sidebar).
    public var hiddenSidebarItems: Set<String> = []
    public var nowPlayingBackground = NowPlayingBackground.animated
    public var startPage = StartPage.home
    public var songColumns: Set<SongColumn> = []

    public static let defaultsKey = "appearanceSettings"

    public init() {}

    public func shows(_ sidebarKey: String) -> Bool { !hiddenSidebarItems.contains(sidebarKey) }

    public mutating func setShown(_ sidebarKey: String, _ shown: Bool) {
        if shown { hiddenSidebarItems.remove(sidebarKey) } else { hiddenSidebarItems.insert(sidebarKey) }
    }

    /// Shown columns of the library table, or of the iPod table when `device`.
    public func tableColumns(device: Bool) -> [SongsTableColumn] { device ? deviceTableColumns : tableColumns }

    public func shows(_ column: SongsTableColumn, device: Bool = false) -> Bool { tableColumns(device: device).contains(column) }

    /// A shown column goes at the end; the title cannot be hidden.
    public mutating func setShown(_ column: SongsTableColumn, _ shown: Bool, device: Bool = false) {
        var columns = tableColumns(device: device)
        if shown, !columns.contains(column) { columns.append(column) } else if !shown { columns.removeAll { $0 == column } }
        setTableColumns(columns, device: device)
    }

    /// Sets the shown columns and their order, e.g. after a drag in the table header.
    public mutating func setTableColumns(_ columns: [SongsTableColumn], device: Bool = false) {
        var seen = Set<SongsTableColumn>()
        let unique = columns.filter { seen.insert($0).inserted }
        let result = unique.contains(.title) ? unique : [.title] + unique
        if device { deviceTableColumns = result } else { tableColumns = result }
    }

    /// Missing or unknown values keep their defaults, so settings of an older or newer version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        accent = c.value(.accent, or: d.accent)
        density = c.value(.density, or: d.density)
        listDensity = c.value(.listDensity, or: d.listDensity)
        setTableColumns(c.value(.tableColumns, or: d.tableColumns.map(\.rawValue)).compactMap(SongsTableColumn.init))
        setTableColumns(c.value(.deviceTableColumns, or: d.deviceTableColumns.map(\.rawValue)).compactMap(SongsTableColumn.init), device: true)
        hiddenSidebarItems = c.value(.hiddenSidebarItems, or: d.hiddenSidebarItems)
        nowPlayingBackground = c.value(.nowPlayingBackground, or: d.nowPlayingBackground)
        startPage = c.value(.startPage, or: d.startPage)
        songColumns = Set(c.value(.songColumns, or: [String]()).compactMap(SongColumn.init))
    }
}
