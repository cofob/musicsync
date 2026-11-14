import Foundation
import Playback
import Testing

@Suite struct QueueTests {
    /// Source a…e playing "b", Play Next "x", Add to Queue "y", AutoPlay "z".
    private func sample() -> PlayQueue<String> {
        var q = PlayQueue<String>()
        q.index = q.replace(["a", "b", "c", "d", "e"], startAt: 1, shuffle: false)
        q.insertLast(["y"])
        q.insertNext(["x"])
        q.appendAutoPlay(["z"])
        return q
    }

    private func names(_ q: PlayQueue<String>, _ origin: QueueOrigin) -> [String] { q.upcoming(origin).map { q.items[$0.index] } }

    @Test func sectionsKeepTheirOrder() {
        let q = sample()
        #expect(q.items == ["a", "b", "x", "y", "c", "d", "e", "z"])
        #expect(q.index == 1)
        #expect(names(q, .user) == ["x", "y"] && names(q, .source) == ["c", "d", "e"] && names(q, .autoPlay) == ["z"])
    }

    @Test func moveAndRemove() {
        var q = sample()
        q.move(from: [6], to: 4)  // "e" before "c"
        #expect(names(q, .source) == ["e", "c", "d"])
        q.move(from: [1], to: 5)  // the current entry stays
        #expect(q.index == 1 && q.items[1] == "b")
        q.remove(at: [0, 2, 1])  // "a" and "x"; not the current one
        #expect(q.items == ["b", "y", "e", "c", "d", "z"] && q.index == 0)
        q.clearUpcoming()
        #expect(q.items == ["b", "z"] && names(q, .autoPlay) == ["z"])
    }

    @Test func keysFollowEntries() {
        var q = sample()
        let key = q.keys[4]  // "c"
        q.move(from: [4], to: 7)
        #expect(q.items[q.keys.firstIndex(of: key)!] == "c")
    }

    @Test func shuffleKeepsCurrentAndUserEntries() {
        var q = sample()
        q.setShuffle(true)
        #expect(q.index == 0 && q.items[0] == "b")
        #expect(names(q, .user) == ["x", "y"] && Array(q.items[1...2]) == ["x", "y"])
        #expect(Set(names(q, .source)) == ["a", "c", "d", "e"] && q.items.last == "z")
        q.insertNext(["w"])
        q.setShuffle(false)
        #expect(q.items == ["a", "b", "w", "x", "y", "c", "d", "e", "z"] && q.index == 1)
    }

    @Test func shuffledStartAndHistory() {
        var q = PlayQueue<String>()
        q.index = q.replace(["a", "b", "c"], startAt: 2, shuffle: true)
        #expect(q.index == 0 && q.items[0] == "c" && Set(q.items) == ["a", "b", "c"])
        q.recordStart()
        q.index = 1
        q.recordStart()
        #expect(q.history == ["c", q.items[1]])
        q.index = q.replace(["d"], startAt: 0, shuffle: false)
        #expect(q.history.count == 2)  // a new list keeps the session history
    }

    @Test func snapshotRoundTripAndFilter() throws {
        let q = sample()
        let snapshot = QueueSnapshot(server: "demo@https://music.example.com", items: q.items, origins: q.origins, index: 1,
                                     elapsed: 42, shuffle: true, repeatMode: "all")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try snapshot.save(to: url)
        let loaded = try #require(QueueSnapshot<String>.load(from: url))
        #expect(loaded.items == q.items && loaded.origins == q.origins && loaded.index == 1 && loaded.elapsed == 42)
        #expect(loaded.shuffle && loaded.repeatMode == "all" && loaded.server == snapshot.server)
        let restored = PlayQueue(items: loaded.items, origins: loaded.origins, index: loaded.index)
        #expect(names(restored, .user) == ["x", "y"])

        // A missing current song: the next one kept is current, from its start.
        let gone = try #require(loaded.filtered { $0 != "b" })
        #expect(gone.items.first == "a" && gone.items[gone.index] == "x" && gone.elapsed == 0 && gone.origins[gone.index] == .user)
        #expect(loaded.filtered { $0 != "z" }?.elapsed == 42)
        #expect(loaded.filtered { $0 == "a" }?.index == 0)
        #expect(loaded.filtered { _ in false } == nil)
        #expect(QueueSnapshot<String>.load(from: url.appendingPathExtension("none")) == nil)
    }

    @Test func throttle() {
        var t = SaveThrottle(minimumGap: 10, interval: 30)
        /// Fires at `s` seconds; true when a save ran.
        func fire(_ s: Double) -> Bool { t.fire(now: Date(timeIntervalSince1970: s)) }
        t.request(now: Date(timeIntervalSince1970: 0))
        let first = fire(0)
        t.request(now: Date(timeIntervalSince1970: 3))  // a pause 3 s later waits for the gap
        let early = fire(9), gap = fire(10), again = fire(11)
        #expect(first && !early && gap && !again)
        t.playing(now: Date(timeIntervalSince1970: 20))  // 10 s after the last save: not yet
        let soon = fire(20)
        t.playing(now: Date(timeIntervalSince1970: 40))
        let periodic = fire(40)
        #expect(!soon && periodic && t.lastSave == Date(timeIntervalSince1970: 40))
        var fresh = SaveThrottle(minimumGap: 10, interval: 30)
        fresh.playing(now: Date(timeIntervalSince1970: 0))
        #expect(fresh.due == Date(timeIntervalSince1970: 0))
    }

    @Test func handoff() {
        let now = Date(timeIntervalSince1970: 5000)
        let remote = RemoteQueueState(current: "s-2", position: 61, changed: now, changedBy: "feishin")
        let idle: (current: String?, position: TimeInterval) = (nil, 0)
        #expect(QueueHandoff.offers(remote, client: "MusicSync", saved: nil, handled: nil, local: idle))
        // Already handled (resumed or dismissed), or older.
        #expect(!QueueHandoff.offers(remote, client: "MusicSync", saved: nil, handled: now, local: idle))
        #expect(QueueHandoff.offers(remote, client: "MusicSync", saved: nil, handled: now.addingTimeInterval(-1), local: idle))
        // This Mac is there already.
        #expect(!QueueHandoff.offers(remote, client: "MusicSync", saved: nil, handled: nil, local: ("s-2", 55)))
        #expect(QueueHandoff.offers(remote, client: "MusicSync", saved: nil, handled: nil, local: ("s-2", 10)))
        // Its own save, and another Mac with this app.
        var own = remote
        own.changedBy = "MusicSync"
        let saved = RemoteQueueState(current: "s-2", position: 61.5, changed: nil, changedBy: nil)
        #expect(!QueueHandoff.offers(own, client: "MusicSync", saved: saved, handled: nil, local: idle))
        own.position = 200
        #expect(QueueHandoff.offers(own, client: "MusicSync", saved: saved, handled: nil, local: idle))
        // Saved by the last run here: the restored queue is at that song.
        #expect(!QueueHandoff.offers(own, client: "MusicSync", saved: nil, handled: nil, local: ("s-2", 170)))
        #expect(QueueHandoff.offers(own, client: "MusicSync", saved: nil, handled: nil, local: ("s-9", 0)))
        // Nothing to go on with.
        #expect(!QueueHandoff.offers(RemoteQueueState(current: nil, position: 0, changed: now, changedBy: "x"),
                                     client: "MusicSync", saved: nil, handled: nil, local: idle))
    }
}
