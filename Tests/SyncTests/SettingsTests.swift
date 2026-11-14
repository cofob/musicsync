import Foundation
import ITunesDB
import Testing
@testable import Sync
import Transcode

@Suite struct SyncSettingsTests {
    @Test func olderSettingsGetNewDefaults() throws {
        let s = try JSONDecoder().decode(SyncSettings.self, from: Data(#"{"presetID":"rockbox-opus","fullAlbums":true}"#.utf8))
        #expect(s.presetID == "rockbox-opus" && s.fullAlbums)
        #expect(s.aacBitrate == 256 && s.opusBitrate == 128 && s.keepFreeGB == 0.5 && s.rockboxCoverSize == 500)
        #expect(!s.autoSync && s.sendPlayCounts && s.deviceNames.isEmpty)
        #expect(s.reserveBytes == SyncPlanner.reserveBytes)
    }

    @Test func roundTrip() throws {
        var s = SyncSettings()
        s.aacBitrate = 192
        s.keepFreeGB = 2
        s.autoSync = true
        s.sendPlayCounts = false
        s.deviceNames = ["U": "Pod"]
        let back = try JSONDecoder().decode(SyncSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.reserveBytes == 2_000_000_000)
    }

    @Test func presetsTakeTheBitrates() {
        var s = SyncSettings()
        s.aacBitrate = 320
        s.opusBitrate = 96
        let presets = Dictionary(uniqueKeysWithValues: s.presets.map { ($0.id, $0) })
        #expect(presets["stock-aac"]?.codec == .aac(.cvbr(bitrateKbps: 320)))
        #expect(presets["rockbox-opus"]?.codec == .opus(bitrateKbps: 96))
        #expect(presets["stock-aac"]?.name == "iPod AAC 320k" && presets["rockbox-opus"]?.name == "Opus 96k")
        #expect(presets["rockbox-flac"] == .rockboxFLAC && presets["stock-alac"] == .stockALAC)
        // Same version: songs on the iPod are not converted again.
        #expect(presets["stock-aac"]?.version == Preset.stockAAC.version)
        #expect(SyncSettings().presets == Preset.builtIns)
    }

    @Test func renameIsAStockChange() {
        var plan = SyncPlan()
        #expect(plan.isEmpty && !plan.touchesStock)
        plan.rename = "Pod"
        #expect(!plan.isEmpty && plan.touchesStock)
    }

    @Test func plannerUsesTheReserve() {
        let input = { (reserve: Int64) in
            PlannerInput(desired: [], manifest: Manifest(), library: DeviceLibrary(db: .empty(name: "iPod"), manifest: Manifest()), freeBytes: 1_000_000_000, reserveBytes: reserve)
        }
        #expect(SyncPlanner.plan(input(500_000_000)).fits)
        #expect(!SyncPlanner.plan(input(2_000_000_000)).fits)
    }
}

extension EndToEndTests {
    @Test func playCountsStayLocalWhenSendingIsOff() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let selection = Self.selection(playlists: [])
        _ = await runSync(try await makePlan(selection: selection, server: f.server, pod: f.pod), pod: f.pod, server: f.server)
        let order = try f.pod.database().tracks.map(\.title)
        try Self.writePlayCounts(order.map { PlayCountEntry(playCount: $0 == "First" ? 2 : 0, lastPlayed: nil, rating: 0) },
                                 to: f.pod.device.playCountsURL)
        var settings = f.pod.settings()
        settings.sendPlayCounts = false
        let run = await runSync(try await makePlan(selection: selection, server: f.server, pod: f.pod), pod: f.pod, server: f.server,
                                settings: settings)
        #expect(run.error == nil && run.summary?.scrobblesSent == 0 && f.server.scrobbles.isEmpty)
        #expect(try f.pod.database().tracks.first { $0.title == "First" }?.playCount == 5)
    }

    @Test func renameWritesTheName() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var plan = SyncPlan()
        plan.freeBytes = 10_000_000_000
        plan.rename = "Road Pod"
        let run = await runSync(plan, pod: f.pod, server: f.server)
        #expect(run.error == nil)
        #expect(try f.pod.database().name == "Road Pod")
        #expect(Hash58.verify(try Data(contentsOf: f.pod.device.iTunesDBURL), guid: f.pod.guid))
    }
}
