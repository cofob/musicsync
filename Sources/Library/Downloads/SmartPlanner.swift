import Foundation
import Subsonic

/// What smart downloads keep after one evaluation.
public struct SmartPlan: Equatable, Sendable {
    /// Kept songs of each rule, in the rule's order. Disabled rules have none.
    public var songs: [SmartRule: [Song]] = [:]
    /// Songs that are new to the store, sorted by id.
    public var added: [String] = []
    /// Songs only rules kept that go now, sorted by id.
    public var removed: [String] = []
    /// Bytes the kept songs take that user downloads do not already take.
    public var bytes: Int64 = 0
}

/// Picks the songs smart downloads keep. Pure and deterministic: the same input gives the same plan.
public enum SmartPlanner {
    /// Kept free on the disk.
    public static let reserveBytes: Int64 = 2_000_000_000

    /// `candidates`: the songs each rule wants, best first. Each rule takes its best songs within its own budget; when
    /// they do not fit the global budget (or the free disk space less `reserveBytes`), the least recently played go first.
    /// Songs the user keeps cost nothing, as they stay anyway. `estimate` sizes songs that are not downloaded yet.
    public static func plan(_ candidates: [SmartRule: [Song]], settings: SmartSettings, entries: [DownloadEntry],
                            lastPlayed: [String: Date], freeDisk: Int64?, estimate: (Song) -> Int64) -> SmartPlan {
        let stored = Dictionary(entries.map { ($0.id, $0) }) { a, _ in a }
        func cost(_ song: Song) -> Int64 {
            guard let entry = stored[song.id] else { return estimate(song) }
            if entry.isUserKept { return 0 }
            return entry.state == .done ? entry.size : estimate(entry.song)
        }

        var chosen: [SmartRule: [Song]] = [:]
        var rank: [String: Int] = [:]
        var songs: [String: Song] = [:]
        for rule in SmartRule.allCases where settings[rule].isOn {
            let budget = SmartSettings.bytes(settings[rule].budgetGB)
            var used: Int64 = 0, seen = Set<String>(), list: [Song] = []
            for (i, song) in (candidates[rule] ?? []).enumerated() where seen.insert(song.id).inserted {
                let size = cost(song)
                guard used + size <= budget else { continue }
                used += size
                list.append(song)
                rank[song.id] = min(rank[song.id] ?? i, i)
                songs[song.id] = song
            }
            chosen[rule] = list
        }

        // Smart files on disk free their space when they go.
        let onDisk = entries.reduce(Int64(0)) { $0 + (!$1.isUserKept && $1.state == .done ? $1.size : 0) }
        var room = SmartSettings.bytes(settings.budgetGB)
        if let freeDisk { room = min(room, max(0, onDisk + freeDisk - reserveBytes)) }

        let order = songs.keys.sorted { a, b in
            let x = lastPlayed[a] ?? .distantPast, y = lastPlayed[b] ?? .distantPast
            if x != y { return x > y }
            if rank[a] != rank[b] { return rank[a] ?? 0 < rank[b] ?? 0 }
            return a < b
        }
        var keep = Set<String>(), used: Int64 = 0
        for id in order {
            guard let song = songs[id] else { continue }
            let size = cost(song)
            guard used + size <= room else { continue }
            used += size
            keep.insert(id)
        }

        return SmartPlan(
            songs: chosen.mapValues { $0.filter { keep.contains($0.id) } },
            added: keep.filter { stored[$0] == nil }.sorted(),
            removed: entries.filter { !$0.isUserKept && !$0.smartRules.isEmpty && !keep.contains($0.id) }.map(\.id).sorted(),
            bytes: used)
    }
}
