import Foundation

/// Where a queue entry came from; the Up Next panel shows one section per origin.
public enum QueueOrigin: String, Codable, Sendable {
    /// The album, playlist or list that was played ("Continue Playing").
    case source
    /// Play Next and Add to Queue ("Playing Next").
    case user
    /// Similar songs added when the queue ends.
    case autoPlay
}

/// The play queue: entries in play order and the current position.
/// Upcoming entries stay grouped by origin: user-added first, then the source, then AutoPlay.
/// Shuffle mixes only the source entries; the current entry and the user-added ones keep their place.
public struct PlayQueue<Item: Sendable>: Sendable {
    /// One entry of a section: its queue index and a key that stays the same while the entry moves.
    public struct Slot: Identifiable, Hashable, Sendable {
        public let id: Int
        public let index: Int
    }

    public private(set) var items: [Item] = []
    public private(set) var origins: [QueueOrigin] = []
    /// Stable entry identities, for list rows and for undoing a shuffle.
    public private(set) var keys: [Int] = []
    public var index: Int?
    /// Entries that started playing this session, oldest first; the last one is the current entry.
    public private(set) var history: [Item] = []
    /// Keys of the source entries in their order before shuffling; nil when not shuffled.
    private var unshuffled: [Int]?
    private var nextKey = 0

    public init() {}

    /// A saved queue; `origins` must have one value per item.
    public init(items: [Item], origins: [QueueOrigin], index: Int?) {
        self.init()
        append(items, origins.count == items.count ? origins : items.map { _ in .source }, at: 0)
        self.index = index.flatMap { items.indices.contains($0) ? $0 : nil }
    }

    /// Replaces the queue with `list`; returns the index to start at. With `shuffle` the entry at `startAt`
    /// (a random one when `randomStart`) comes first and the rest follows in random order.
    public mutating func replace(_ list: [Item], startAt: Int, shuffle: Bool, randomStart: Bool = false) -> Int {
        removeAll()
        append(list, list.map { _ in .source }, at: 0)
        guard shuffle, !keys.isEmpty else { unshuffled = nil; return min(max(startAt, 0), items.count - 1) }
        unshuffled = keys
        let first = randomStart ? Int.random(in: keys.indices) : min(max(startAt, 0), keys.count - 1)
        reorder([first] + keys.indices.filter { $0 != first }.shuffled())
        return 0
    }

    /// Play Next: right after the current entry.
    public mutating func insertNext(_ list: [Item]) {
        append(list, list.map { _ in .user }, at: upcomingStart)
    }

    /// Add to Queue: after the other user-added entries, before the rest of the source.
    public mutating func insertLast(_ list: [Item]) {
        let end = upcoming(.user).last.map { $0.index + 1 } ?? upcomingStart
        append(list, list.map { _ in .user }, at: end)
    }

    /// AutoPlay: at the end.
    public mutating func appendAutoPlay(_ list: [Item]) {
        append(list, list.map { _ in .autoPlay }, at: items.count)
    }

    /// Removes entries by queue index; the current entry stays.
    public mutating func remove(at offsets: IndexSet) {
        let gone = IndexSet(offsets.filter { items.indices.contains($0) && $0 != index })
        guard !gone.isEmpty else { return }
        let removedKeys = Set(gone.map { keys[$0] })
        if let index { self.index = index - gone.count(in: 0..<index) }
        reorder(items.indices.filter { !gone.contains($0) })
        unshuffled?.removeAll { removedKeys.contains($0) }
    }

    /// Moves entries by queue index, as `Array.move(fromOffsets:toOffset:)`; the current entry keeps its index.
    public mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = IndexSet(offsets.filter { items.indices.contains($0) && $0 != index })
        guard !moving.isEmpty else { return }
        let target = min(max(destination, upcomingStart), items.count)
        let rest = items.indices.filter { !moving.contains($0) }, split = target - moving.count(in: 0..<target)
        let current = index.map { keys[$0] }
        reorder(rest[..<split] + Array(moving) + rest[split...])
        index = current.flatMap { keys.firstIndex(of: $0) }
    }

    /// Removes the upcoming user-added and source entries; AutoPlay stays.
    public mutating func clearUpcoming() {
        remove(at: IndexSet((upcoming(.user) + upcoming(.source)).map(\.index)))
    }

    /// Turns shuffle on (the source entries after the current one in random order) or off (their order before).
    public mutating func setShuffle(_ on: Bool) {
        guard let index else { unshuffled = on ? keys : nil; return }
        let users = upcoming(.user).map(\.index), auto = upcoming(.autoPlay).map(\.index)
        if on {
            unshuffled = indices(of: .source).map { keys[$0] }
            let rest = indices(of: .source).filter { $0 != index }.shuffled()
            reorder([index] + users + rest + auto)
            self.index = 0
        } else if let original = unshuffled {
            let position = Dictionary(keys.enumerated().map { ($1, $0) }) { a, _ in a }
            let sources = original.compactMap { position[$0] }
            let split = sources.firstIndex(of: index) ?? 0
            let before = Array(sources[..<split]), after = sources[split...].filter { $0 != index }
            reorder(before + [index] + users + after + auto)
            self.index = before.count
            unshuffled = nil
        }
    }

    /// Notes that the current entry started playing.
    public mutating func recordStart() {
        guard let index, items.indices.contains(index) else { return }
        history = Array((history + [items[index]]).suffix(Self.historyLimit))
    }

    public static var historyLimit: Int { 200 }

    /// Upcoming entries of one origin, in play order.
    public func upcoming(_ origin: QueueOrigin) -> [Slot] {
        (upcomingStart..<items.count).filter { origins[$0] == origin }.map { Slot(id: keys[$0], index: $0) }
    }

    private var upcomingStart: Int { (index ?? -1) + 1 }

    private func indices(of origin: QueueOrigin) -> [Int] { items.indices.filter { origins[$0] == origin } }

    private mutating func append(_ list: [Item], _ kinds: [QueueOrigin], at position: Int) {
        items.insert(contentsOf: list, at: position)
        origins.insert(contentsOf: kinds, at: position)
        keys.insert(contentsOf: (0..<list.count).map { nextKey + $0 }, at: position)
        nextKey += list.count
        if let index, position <= index { self.index = index + list.count }
    }

    /// Puts the entries in the order of `order` (old queue indexes); entries left out are dropped.
    private mutating func reorder(_ order: [Int]) {
        items = order.map { items[$0] }
        origins = order.map { origins[$0] }
        keys = order.map { keys[$0] }
    }

    private mutating func removeAll() {
        items = []; origins = []; keys = []; index = nil
    }
}
