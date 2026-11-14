import AppKit
import Library
import Playback
import Subsonic
import Support

/// `check:soak`: random user actions for `MUSICSYNC_SOAK_MINUTES` (default 3) against `scripts/big-server.py` with
/// faults on (`FAULT_*`), while a `HangMeter` watches the main thread. Fails on a stall over 500 ms, on a player
/// state that does not add up, and when the app does not play again after a server outage or a refused password.
/// `MUSICSYNC_SOAK_SERVER2` (a second stub) adds server switches. `MUSICSYNC_SOAK_OFFLINE=1` is the second run:
/// the stub stopped, the same `MUSICSYNC_DEMO_DIR`, so only the songs downloaded by the first run can play.
extension ShotChecks {
    static func soak(_ model: AppModel) async {
        guard let base = model.config?.baseURL, base.host == "127.0.0.1" else { return check(false, "soak needs MUSICSYNC_DEMO_SERVER on 127.0.0.1") }
        let env = ProcessInfo.processInfo.environment
        let run = Soak(model, base: base, minutes: Double(env["MUSICSYNC_SOAK_MINUTES"] ?? "") ?? 3,
                       seed: UInt64(env["MUSICSYNC_SOAK_SEED"] ?? "") ?? UInt64(Date().timeIntervalSince1970))
        let settings = model.player.settings
        if env["MUSICSYNC_SOAK_OFFLINE"] == "1" { await run.offline() } else { await run.online(other: env["MUSICSYNC_SOAK_SERVER2"].flatMap(URL.init(string:))) }
        model.player.settings = settings
        run.finish()
    }
}

/// One soak run: the actions, the state checks after each of them and the log.
@MainActor private final class Soak {
    let model: AppModel
    let base: URL
    let deadline: Date
    var random: SplitMix
    let meter = HangMeter()
    var worst = (ms: 0, step: "")
    var steps = 0
    var broken: [String] = []
    /// Error message -> times it appeared.
    var messages: [String: Int] = [:]
    var lastShown: [String?] = [nil, nil, nil, nil]
    var player: Player { model.player }

    init(_ model: AppModel, base: URL, minutes: Double, seed: UInt64) {
        self.model = model
        self.base = base
        deadline = Date().addingTimeInterval(minutes * 60)
        random = SplitMix(seed: seed)
        log("soak: seed \(seed), \(minutes) min")
    }

    // MARK: Runs

    func online(other: URL?) async {
        _ = await ShotChecks.wait { !self.model.albums.isEmpty }
        let start = Date(), length = deadline.timeIntervalSince(start)
        var events: [(at: Double, name: String, action: () async -> Void)] = [
            (0.3, "outage", { await self.outage() }),
            (0.6, "auth", { await self.refusedPassword() }),
        ]
        if let other { events.append((0.45, "switch", { await self.switchServer(to: other) })) }
        events.sort { $0.at < $1.at }
        while Date() < deadline {
            if let event = events.first, Date().timeIntervalSince(start) >= event.at * length {
                events.removeFirst()
                await step(event.name, settle: 0) { await event.action() }
                continue
            }
            await randomAction(online: true)
        }
        await step("downloads") {}
        let done = model.downloads.entries.values.filter { $0.state == .done }.count
        check(!model.downloads.pins.isEmpty && done > 0, "some downloads finished (\(model.downloads.pins.count) pins, \(done) songs)")
    }

    func offline() async {
        check(await ShotChecks.wait { self.model.downloads.isOffline }, "offline at launch")
        let done = model.downloads.entries.values.filter { $0.state == .done }.map(\.song)
        guard !done.isEmpty else { return check(false, "songs downloaded by the first run") }
        await step("play downloaded") { player.play(done) }
        check(await ShotChecks.wait { self.player.isPlaying && self.player.elapsed > 1 }, "a downloaded song plays offline")
        // Neither downloaded nor in the playback cache.
        for album in model.albums.prefix(50) {
            guard let songs = try? await model.album(album.id)?.song, !songs.isEmpty, !songs.contains(where: model.downloads.isAvailable) else { continue }
            await step("play not downloaded") { player.play(songs) }
            check(player.current == nil && !player.isPlaying, "an album that is not downloaded does not play offline")
            break
        }
        while Date() < deadline { await randomAction(online: false) }
    }

    func finish() {
        meter.stop()
        log("soak: \(steps) steps, worst stall \(worst.ms) ms (\(worst.step))")
        for (message, count) in messages.sorted(by: { $0.value > $1.value }) { log("soak: message ×\(count): \(message)") }
        check(worst.ms <= 500, "soak: longest main-thread stall \(worst.ms) ms (\(worst.step))")
        check(broken.isEmpty, "soak: player state consistent (\(broken.count) problems: \(broken.prefix(5)))")
        check(messages.keys.allSatisfy { !$0.isEmpty }, "soak: every error has a message")
    }

    // MARK: Actions

    func randomAction(online: Bool) async {
        let albums = model.albums
        let saved = model.downloads.pins.compactMap { pin -> String? in if case .album(let id) = pin.reason { id } else { nil } }
        switch random.next(below: online ? 16 : 12) {
        case 0: if let album = pick(online ? albums.map(\.id) : saved) {
            await step("play album") { if let full = model.downloads.savedAlbum(album) ?? albums.first(where: { $0.id == album }) { model.play(full) } }
        }
        case 1: await step("next") { player.next() }
        case 2: await step("previous") { player.previous() }
        case 3: await step("seek") { player.seek(to: Double(random.next(below: max(1, Int(player.duration))))) }
        case 4: await step("play/pause") { player.toggle() }
        case 5: await step("transitions") {
            let all = PlaybackSettings.Transitions.allCases
            player.settings.transitions = all[random.next(below: all.count)]
        }
        case 6: let pages: [SidebarItem] = [.home, .albums, .artists, .songs, .genres, .favorites, .downloaded, .playlists]
            await step("page") { await Shot.select(pages[random.next(below: pages.count)], model) }
        case 7: if let album = albums.isEmpty ? nil : albums[random.next(below: albums.count)] { await step("open album") { model.show(.album(album)) } }
        case 8: await step("search") {
            await Shot.select(.search, model)
            model.search.commit(["night", "echo", "blue", "zzz", "Ночь"][random.next(below: 5)])
        }
        case 9: await step("queue edit") {
            if !player.upcoming.isEmpty { player.removeUpcoming(at: [random.next(below: player.upcoming.count)]) }
            if player.upcoming.count > 2 { player.moveUpcoming(from: [0], to: player.upcoming.count) }
        }
        case 10: await step("shuffle/repeat") {
            if random.next(below: 2) == 0 { player.setShuffle(!player.shuffle) } else { player.repeatMode = player.repeatMode.next }
        }
        case 11: await step("skip burst", settle: 0.2) { for _ in 0..<5 { player.next() } }
        case 12: if let playlist = pick(model.playlists.map(\.id)), let found = model.playlists.first(where: { $0.id == playlist }) {
            await step("play playlist") { model.play(found) }
        }
        case 13: if let mix = model.mixes.mixes.isEmpty ? nil : model.mixes.mixes[random.next(below: model.mixes.mixes.count)] {
            await step("play mix") { model.mixes.play(mix) }
        }
        case 14: if model.downloads.pins.count < 4, let album = albums.isEmpty ? nil : albums[random.next(below: albums.count)] {
            await step("download") { model.download(album) }
        }
        default: await step("offline toggle") { model.downloads.isOffline.toggle() }
        }
    }

    /// The server stops listening for 15 s; once it is back, the app plays again.
    func outage() async {
        await fault("outage=15")
        for _ in 0..<5 { await randomAction(online: true) }
        try? await Task.sleep(for: .seconds(16))
        await recovered("after the outage")
    }

    /// The server refuses the password for 10 s, then takes it again.
    func refusedPassword() async {
        await fault("auth=10")
        for _ in 0..<4 { await randomAction(online: true) }
        try? await Task.sleep(for: .seconds(11))
        await recovered("after the refused password")
    }

    /// Switches to the second stub and back, playing on each.
    func switchServer(to other: URL) async {
        for url in [other, base] {
            await model.save(ServerConfig(baseURL: url, username: "demo"), password: "")
            _ = await ShotChecks.wait { !self.model.albums.isEmpty }
            for _ in 0..<6 { await randomAction(online: true) }
            check(model.config?.baseURL == url && player.queue.allSatisfy { if case .server = $0 { true } else { false } },
                  "switched to \(url.port ?? 0)")
        }
        await recovered("after the server switch")
    }

    /// With the random faults off, an album plays from the server and the offline flag clears.
    func recovered(_ when: String) async {
        await fault("random=0")
        defer { Task { await fault("random=1") } }
        if model.downloads.isOffline { model.downloads.isOffline = false }
        guard let album = model.albums.first(where: { model.downloads.savedAlbum($0.id) == nil }) else { return check(false, "an album to play \(when)") }
        player.repeatMode = .off
        model.play(album)
        let plays = await ShotChecks.wait {
            self.player.current?.album == album.name && self.player.isPlaying && self.player.elapsed > 1
        }
        check(plays, "a server album plays \(when) (\(player.current?.title ?? "nothing"), \(player.errorMessage ?? "no error"))")
    }

    // MARK: Checks

    /// Runs one action, then watches the state for `settle` seconds and takes the longest stall.
    func step(_ name: String, settle: Double? = nil, _ action: () async -> Void) async {
        steps += 1
        _ = meter.lap()
        await action()
        let end = Date().addingTimeInterval(settle ?? 0.3 + Double(random.next(below: 1500)) / 1000)
        repeat {
            verify(after: name)
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < end
        let ms = Int(meter.lap() * 1000)
        if ms > worst.ms { worst = (ms, name) }
        if ms > 500 { log("soak: \(ms) ms stall in \(name)") }
    }

    /// The player's parts agree; error messages are counted and the alert is dismissed.
    func verify(after step: String) {
        func problem(_ what: String) {
            if broken.count < 50 { broken.append("\(step): \(what)") }
            if broken.count <= 10 { log("soak: \(step): \(what)") }
        }
        if let index = player.index, !player.queue.indices.contains(index) { problem("index \(index) of \(player.queue.count)") }
        if player.index == nil, player.mixer.hasCurrent { problem("the mixer plays with no current entry") }
        if let next = player.nextIndex, !player.queue.indices.contains(next) { problem("next index \(next) of \(player.queue.count)") }
        if !player.elapsed.isFinite || player.elapsed < 0 || (player.duration > 0 && player.elapsed > player.duration + 1) {
            problem("elapsed \(player.elapsed) of \(player.duration)")
        }
        if player.remote == nil, player.isPlaying != player.mixer.isPlaying { problem("isPlaying \(player.isPlaying), mixer \(player.mixer.isPlaying)") }
        let shown = [model.errorMessage, player.errorMessage, model.libraryError, model.search.error]
        for (message, before) in zip(shown, lastShown) where message != before { message.map { messages[$0, default: 0] += 1 } }
        lastShown = shown
        dismissAlert()
    }

    /// Clicks OK in the error alert, as the user does; setting the message to nil from code inside a view update crashed AppKit.
    func dismissAlert() {
        guard let sheet = ShotChecks.mainWindow?.attachedSheet, sheet.isVisible else { return }
        func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        sheet.contentView.flatMap(buttons)?.first { $0.title == "OK" }?.performClick(nil)
    }

    func check(_ ok: Bool, _ what: String) { ShotChecks.check(ok, what) }

    func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    func pick(_ ids: [String]) -> String? { ids.isEmpty ? nil : ids[random.next(below: ids.count)] }

    /// The stub's fault switch (`scripts/big-server.py`).
    func fault(_ query: String) async {
        guard let url = URL(string: "fault?\(query)", relativeTo: base) else { return }
        _ = try? await URLSession.shared.data(from: url)
    }
}

/// A small seeded generator, so a failing run can be repeated with `MUSICSYNC_SOAK_SEED`.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(below n: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(n, 1)))
    }
}
