/// Rows selected in a list by click, ⌘-click and ⇧-click, as in Finder and Music. It keeps row ids, not
/// positions, so the selection stays on its rows when the list is sorted or filtered.
public struct ListSelection<ID: Hashable>: Equatable {
    public private(set) var selected: Set<ID> = []
    /// The row a ⇧-click extends from: the last row clicked without ⇧.
    public private(set) var anchor: ID?
    /// The selection before the current ⇧-click range, which a new ⇧-click replaces.
    private var base: Set<ID> = []

    public init() {}

    public var count: Int { selected.count }
    public var isEmpty: Bool { selected.isEmpty }
    public func contains(_ id: ID) -> Bool { selected.contains(id) }

    /// Click: only this row.
    public mutating func click(_ id: ID) {
        selected = [id]
        anchor = id
        base = selected
    }

    /// ⌘-click: adds or removes the row.
    public mutating func toggle(_ id: ID) {
        if selected.remove(id) == nil { selected.insert(id) }
        anchor = id
        base = selected
    }

    /// ⇧-click: adds the rows from the anchor to this row in `ids` order. Without an anchor in the list it is a click.
    public mutating func extend(to id: ID, in ids: [ID]) {
        guard let anchor, let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) else { return click(id) }
        selected = base.union(ids[min(from, to)...max(from, to)])
    }

    public mutating func selectAll(_ ids: [ID]) {
        selected = Set(ids)
        anchor = ids.first
        base = selected
    }

    /// Arrow keys: only the row `offset` rows from the anchor, within `ids`; with no anchor in `ids`, the first
    /// row going down or the last going up.
    public mutating func move(_ offset: Int, in ids: [ID]) {
        guard !ids.isEmpty else { return }
        let to = anchor.flatMap(ids.firstIndex).map { min(max($0 + offset, 0), ids.count - 1) } ?? (offset > 0 ? 0 : ids.count - 1)
        click(ids[to])
    }

    public mutating func clear() {
        selected = []
        anchor = nil
        base = []
    }

    /// The selected rows that are still in `ids`, in `ids` order.
    public func ordered(in ids: [ID]) -> [ID] { ids.filter(selected.contains) }
}
