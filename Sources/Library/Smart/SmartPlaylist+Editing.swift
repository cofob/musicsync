import Foundation

/// Changes the editor makes to the rules, by rule or group id.
extension SmartPlaylist.Group {
    /// The rule with this id, here or in a nested group.
    public subscript(rule id: UUID) -> SmartPlaylist.Rule? {
        get {
            for item in items {
                switch item {
                case .rule(let rule) where rule.id == id: return rule
                case .group(let group): if let rule = group[rule: id] { return rule }
                default: break
                }
            }
            return nil
        }
        set {
            guard let newValue else { return }
            for i in items.indices {
                switch items[i] {
                case .rule(let rule) where rule.id == id: items[i] = .rule(newValue)
                case .group(var group) where group[rule: id] != nil:
                    group[rule: id] = newValue
                    items[i] = .group(group)
                default: break
                }
            }
        }
    }

    public subscript(group id: UUID) -> SmartPlaylist.Group? {
        get { items.lazy.compactMap { if case .group(let g) = $0, g.id == id { g } else { nil } }.first }
        set {
            guard let newValue, let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i] = .group(newValue)
        }
    }

    /// Puts `item` after the item with `id`, in the group that holds it.
    public mutating func insert(_ item: SmartPlaylist.Item, after id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { return items.insert(item, at: i + 1) }
        for i in items.indices {
            guard case .group(var group) = items[i], group.contains(id) else { continue }
            group.insert(item, after: id)
            items[i] = .group(group)
        }
    }

    /// Removes the item with `id`; a nested group left empty goes too.
    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        for i in items.indices.reversed() {
            guard case .group(var group) = items[i], group.contains(id) else { continue }
            group.remove(id)
            if group.items.isEmpty { items.remove(at: i) } else { items[i] = .group(group) }
        }
    }

    func contains(_ id: UUID) -> Bool {
        items.contains { item in
            if item.id == id { return true }
            if case .group(let group) = item { return group.contains(id) }
            return false
        }
    }
}
