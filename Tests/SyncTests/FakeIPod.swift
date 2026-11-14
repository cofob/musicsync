import Foundation
import Testing
@testable import Artwork
@testable import Device
@testable import ITunesDB
@testable import Subsonic
@testable import Sync
@testable import Transcode

let testGuid = "000A27001234ABCD"
let ffmpegTools = FFmpeg.locate()

/// A temp directory laid out like an iPod, with a signed database that holds one foreign track.
struct FakeIPod {
    let root: URL
    let device: IPodDevice
    let locations: SyncLocations

    static func make(withDatabase: Bool = true, foreignTracks: Int = 1) throws -> FakeIPod {
        let root = try tempDirectory("fake-ipod")
        let volume = root.appendingPathComponent("volume")
        try FileManager.default.createDirectory(at: volume.appendingPathComponent("iPod_Control"), withIntermediateDirectories: true)
        let device = IPodDevice(mountURL: volume)
        try device.layout.ensureStructure()
        let pod = FakeIPod(root: root, device: device, locations: testLocations(root))
        if withDatabase {
            var db = ITunesDB.empty(name: "Test iPod")
            for n in 1...max(foreignTracks, 1) where n <= foreignTracks {
                let track = makeTrack(n)
                let file = volume.appendingPathComponent(ITunesDB.relativePath(ipodLocation: track.location))
                try Data(repeating: 0xAB, count: 1000).write(to: file)
                db.addTrack(track)
            }
            try pod.write(db)
        }
        return pod
    }

    var guid: [UInt8] { try! Hash58.parseGuid(testGuid) }

    func write(_ db: ITunesDB) throws {
        try FileManager.default.atomicWrite(try db.serialize(firewireGuid: guid), to: device.iTunesDBURL)
    }

    func database() throws -> ITunesDB { try ITunesDB.parse(Data(contentsOf: device.iTunesDBURL)) }

    func settings(guid: Bool = true) -> SyncSettings {
        var s = SyncSettings()
        s.workers = 2
        if guid { s.manualGuids[device.volumeUUID ?? ""] = testGuid }
        return s
    }

    /// The manifest file as written, whatever server it belongs to.
    func manifest() -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: ManifestStore.url(for: device))).flatMap { try? decoder.decode(Manifest.self, from: $0) } ?? Manifest()
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: device.mountURL.appendingPathComponent(relativePath).path)
    }

    func fileSize(_ relativePath: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: device.mountURL.appendingPathComponent(relativePath).path)[.size] as? Int) ?? -1
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

// MARK: Audio fixtures

/// Writes a stereo 44.1 kHz sine of `seconds`, FLAC unless `encode` says otherwise.
func makeFLAC(in dir: URL, name: String, seconds: Double, frequency: Int, encode: [String] = ["-c:a", "flac"]) throws -> URL {
    let ff = try #require(ffmpegTools)
    let url = dir.appendingPathComponent(name)
    let process = Process()
    process.executableURL = ff.ffmpeg
    process.arguments = ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=\(frequency):duration=\(seconds):sample_rate=44100",
                         "-ac", "2"] + encode + [url.path]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return url
}

func songJSON(_ id: String, title: String, track: Int, album: String = "Album One", albumId: String = "al-1",
              file: URL, seconds: Int, extra: [String: Any] = [:]) -> [String: Any] {
    var json: [String: Any] = [
        "id": id, "title": title, "album": album, "albumId": albumId, "artist": "Test Artist", "track": track,
        "discNumber": 1, "year": 2020, "genre": "Rock", "suffix": "flac", "duration": seconds, "bitRate": 900,
        "samplingRate": 44100, "bitDepth": 16, "created": "2024-01-01T00:00:00Z", "coverArt": "cov-\(albumId)",
        "size": (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0,
        "replayGain": ["albumGain": -7.25, "trackGain": -6.5],
    ]
    json.merge(extra) { $1 }
    return json
}

func albumJSON(id: String, name: String, songs: [[String: Any]], year: Int = 2020) -> [String: Any] {
    ["id": id, "name": name, "artist": "Test Artist", "artistId": "ar-1", "year": year, "genre": "Rock",
     "coverArt": "cov-\(id)", "songCount": songs.count, "song": songs]
}

// MARK: Running syncs

func makePlan(selection: Selection, server: StubServer, pod: FakeIPod, soundCheck: SyncSettings.SoundCheckSource = .album,
              freeBytes: Int64 = 10_000_000_000) async throws -> SyncPlan {
    let client = server.client
    let expansion = try await SelectionExpander(client: client)
        .expand(selection, defaultPresetID: "stock-aac", soundCheck: soundCheck)
    let manifest = ManifestStore.load(for: pod.device, serverKey: client.serverKey).manifest
    let library = try DeviceLibrary.load(device: pod.device, manifest: manifest, cacheDirectory: nil)
    return SyncPlanner.plan(PlannerInput(desired: expansion.songs, playlists: expansion.playlists, manifest: manifest,
                                         library: library, freeBytes: freeBytes))
}

struct RunResult {
    var events: [SyncEvent] = []
    var summary: SyncSummary?
    var error: Error?
    var warnings: [String] { events.compactMap { if case .warning(let w) = $0 { w } else { nil } } }
}

/// Runs the engine to the end, optionally cancelling after the first finished item.
func runSync(_ plan: SyncPlan, pod: FakeIPod, server: StubServer, settings: SyncSettings? = nil,
             cancelAfterFirstItem: Bool = false) async -> RunResult {
    let engine = SyncEngine(locations: pod.locations)
    var result = RunResult()
    do {
        for try await event in await engine.run(plan: plan, device: pod.device, client: server.client,
                                                settings: settings ?? pod.settings()) {
            result.events.append(event)
            if case .finished(let summary) = event { result.summary = summary }
            if cancelAfterFirstItem, case .item(_, _, .done) = event { await engine.cancel() }
        }
    } catch { result.error = error }
    return result
}
