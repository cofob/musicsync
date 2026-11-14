import Foundation

/// A section of the Home page.
public enum HomeShelf: String, Codable, CaseIterable, Sendable {
    case topPicks, madeForYou, because, recentlyPlayed, mostPlayed, discover

    public var title: String {
        switch self {
        case .topPicks: "Top Picks for You"
        case .madeForYou: "Made for You"
        case .because: "Because You Listened To"
        case .recentlyPlayed: "Recently Played"
        case .mostPlayed: "Most Played"
        case .discover: "Discover"
        }
    }
}

/// Settings > Library: which Home sections show, and in which order.
public struct HomeSettings: StoredSettings {
    /// Every shelf once, in the user's order.
    public private(set) var order = HomeShelf.allCases
    public var hidden: Set<HomeShelf> = []

    public static let defaultsKey = "homeSettings"

    public init() {}

    /// Shelves to draw, top to bottom.
    public var visible: [HomeShelf] { order.filter { !hidden.contains($0) } }

    public func shows(_ shelf: HomeShelf) -> Bool { !hidden.contains(shelf) }

    public mutating func setShown(_ shelf: HomeShelf, _ shown: Bool) {
        if shown { hidden.remove(shelf) } else { hidden.insert(shelf) }
    }

    /// Moves `shelf` up (negative) or down (positive), within the list.
    public mutating func move(_ shelf: HomeShelf, by offset: Int) {
        guard let from = order.firstIndex(of: shelf) else { return }
        let to = min(max(from + offset, 0), order.count - 1)
        order.remove(at: from)
        order.insert(shelf, at: to)
    }

    /// Unknown shelves are dropped and new ones are added at the end, so every shelf is in `order` once.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var seen = Set<HomeShelf>()
        let saved = c.value(.order, or: [String]()).compactMap(HomeShelf.init).filter { seen.insert($0).inserted }
        order = saved + HomeShelf.allCases.filter { !seen.contains($0) }
        hidden = Set(c.value(.hidden, or: [String]()).compactMap(HomeShelf.init))
    }
}
