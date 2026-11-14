import Foundation
import Testing
@testable import Device

private func makeVolume() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ipod-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url.appendingPathComponent("iPod_Control"), withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Suite struct SysInfoTests {
    @Test func textParse() {
        let info = SysInfo(text: """
        BoardHwName: iPod
        pszSerialNumber: 9C9123ABCDE
        ModelNumStr: xC293
        FirewireGuid: 0x000A2700AABBCCDD
        visibleBuildID: 0x01438000 (1.1.2)
        """)
        #expect(info.modelNumStr == "xC293")
        #expect(info.firewireGuid == "0x000A2700AABBCCDD")
        #expect(info.serialNumber == "9C9123ABCDE")
        #expect(info.visibleBuildID == "0x01438000 (1.1.2)")
    }

    @Test func extendedParse() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>FireWireGUID</key><string>000A2700AABBCCDD</string>
        <key>SerialNumber</key><string>9C9123ABCDE</string>
        <key>DBVersion</key><integer>3</integer>
        <key>AlbumArt</key><array><dict>
        <key>FormatId</key><integer>1060</integer>
        <key>RenderWidth</key><integer>320</integer>
        <key>RenderHeight</key><integer>320</integer>
        </dict></array>
        </dict></plist>
        """
        let info = try #require(SysInfoExtended(data: Data(xml.utf8)))
        #expect(info.fireWireGUID == "000A2700AABBCCDD")
        #expect(info.serialNumber == "9C9123ABCDE")
        #expect(info.dbVersion == 3)
        #expect(info.artworkFormats == [.init(formatID: 1060, width: 320, height: 320)])
        #expect(SysInfoExtended(data: Data("garbage".utf8)) == nil)
    }

    @Test(arguments: [
        ("xC293", "iPod classic 160GB (2009)"), ("MC297", "iPod classic 160GB (2009)"),
        ("xB562", "iPod classic 120GB"), ("MB565", "iPod classic 120GB"),
        ("xB029", "iPod classic 80GB"), ("MB147", "iPod classic 80GB"),
        ("xB145", "iPod classic 160GB (2007)"), ("MB150", "iPod classic 160GB (2007)"),
    ])
    func modelTable(str: String, name: String) {
        #expect(IPodDevice.modelName(forModelNumStr: str) == name)
    }

    @Test func unknownModel() {
        #expect(IPodDevice.modelName(forModelNumStr: "xZZZZ") == nil)
        #expect(IPodDevice.modelName(forModelNumStr: nil) == nil)
    }
}

@Suite struct FirewireGuidTests {
    @Test func parse() {
        let expected: [UInt8] = [0x00, 0x0A, 0x27, 0x00, 0xAA, 0xBB, 0xCC, 0xDD]
        #expect(FirewireGuid.parse("000A2700AABBCCDD") == expected)
        #expect(FirewireGuid.parse("0x000a2700aabbccdd") == expected)
        #expect(FirewireGuid.parse("0X000A2700AABBCCDD\n") == expected)
        #expect(FirewireGuid.parse("") == nil)
        #expect(FirewireGuid.parse("000A2700AABBCC") == nil)
        #expect(FirewireGuid.parse("000A2700AABBCCDG") == nil)
        #expect(FirewireGuid.parse("000A2700AABBCCD\u{FF11}") == nil)  // fullwidth digit
    }

    @Test func chain() throws {
        let volume = try makeVolume()
        defer { try? FileManager.default.removeItem(at: volume) }
        let sysInfo = volume.appendingPathComponent("iPod_Control/Device/SysInfo")
        try write("FirewireGuid: 0x1111111111111111\n", to: sysInfo)
        let device = try #require(IPodDevice.detect(at: volume))
        #expect(FirewireGuid.resolveString(for: device, manualOverride: nil) == "1111111111111111")
        #expect(FirewireGuid.resolveString(for: device, manualOverride: "bad") == "1111111111111111")
        #expect(FirewireGuid.resolveString(for: device, manualOverride: "2222222222222222") == "2222222222222222")

        try write("<plist version=\"1.0\"><dict><key>FireWireGUID</key><string>3333333333333333</string></dict></plist>",
                  to: volume.appendingPathComponent("iPod_Control/Device/SysInfoExtended"))
        #expect(FirewireGuid.resolve(for: device, manualOverride: nil) == Array(repeating: 0x33, count: 8))
    }

    @Test("smoke: IOKit lookup on boot volume does not crash")
    func ioKitSmoke() {
        _ = FirewireGuid.usbSerial(forVolume: URL(fileURLWithPath: "/"))
    }
}

@Suite struct VolumeTests {
    @Test func detect() throws {
        let volume = try makeVolume()
        defer { try? FileManager.default.removeItem(at: volume) }
        let device = try #require(IPodDevice.detect(at: volume))
        #expect(device.iTunesDBURL.path.hasSuffix("iPod_Control/iTunes/iTunesDB"))
        #expect(device.musicSyncDir.path.hasSuffix("iPod_Control/MusicSync"))
        #expect(!device.isRockboxInstalled)
        #expect(device.modelName == nil)
        #expect(try device.capacity().total > 0)

        try FileManager.default.createDirectory(at: volume.appendingPathComponent(".rockbox"), withIntermediateDirectories: true)
        #expect(device.isRockboxInstalled)
        #expect(IPodDevice.detect(at: FileManager.default.temporaryDirectory) == nil)
    }

    @Test func ensureStructure() throws {
        let volume = try makeVolume()
        defer { try? FileManager.default.removeItem(at: volume) }
        let device = try #require(IPodDevice.detect(at: volume))
        try device.layout.ensureStructure()
        for dir in [device.iTunesDir, device.artworkDir, device.deviceDir,
                    device.musicDir.appendingPathComponent("F00"), device.musicDir.appendingPathComponent("F49")] {
            #expect(FileManager.default.fileExists(atPath: dir.path))
        }
        #expect(!FileManager.default.fileExists(atPath: device.musicDir.appendingPathComponent("F50").path))
    }

    @Test func newMusicFilePath() throws {
        let volume = try makeVolume()
        defer { try? FileManager.default.removeItem(at: volume) }
        let layout = try #require(IPodDevice.detect(at: volume)).layout
        let regex = #/iPod_Control/Music/F([0-4][0-9])/[A-Z0-9]{4}\.m4a/#
        var seen = Set<String>()
        for _ in 0..<500 {
            let path = layout.newMusicFilePath(ext: ".m4a", existing: seen)
            let match = try #require(path.wholeMatch(of: regex))
            #expect(Int(match.1)! < 50)
            #expect(seen.insert(path.lowercased()).inserted)
            #expect(FileManager.default.fileExists(atPath: volume.appendingPathComponent((path as NSString).deletingLastPathComponent).path))
        }
    }

    @Test func collisionAvoidance() throws {
        let volume = try makeVolume()
        defer { try? FileManager.default.removeItem(at: volume) }
        let layout = try #require(IPodDevice.detect(at: volume)).layout
        // Every name taken except one: the generator must find it.
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var existing = Set<String>()
        for folder in 0..<50 {
            for _ in 0..<2000 {
                existing.insert("iPod_Control/Music/F\(String(format: "%02d", folder))/\(String((0..<4).map { _ in chars.randomElement()! })).MP3")
            }
        }
        let path = layout.newMusicFilePath(ext: "mp3", existing: existing)
        #expect(!existing.map { $0.lowercased() }.contains(path.lowercased()))
    }

    @Test func orphans() throws {
        let volume = try makeVolume()
        defer { try? FileManager.default.removeItem(at: volume) }
        let device = try #require(IPodDevice.detect(at: volume))
        let music = device.musicDir
        try write("aaaa", to: music.appendingPathComponent("F00/AAAA.m4a"))
        try write("bbbbbb", to: music.appendingPathComponent("F01/BBBB.mp3"))
        try write("c", to: music.appendingPathComponent("F02/CCCC.m4a"))
        try write("junk", to: music.appendingPathComponent("F02/.DS_Store"))

        let found = try device.layout.orphans(referenced: [
            "iPod_Control/Music/f00/aaaa.M4A",          // case differs
            ":iPod_Control:Music:F01:BBBB.mp3",         // iTunesDB form
        ])
        #expect(found.map(\.path) == ["iPod_Control/Music/F02/CCCC.m4a"])
        #expect(found.first?.size == 1)
        #expect(try device.layout.orphans(referenced: []).count == 3)
    }
}

@Test func iTunesDBCacheHitsUntilTheFileChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbcache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = root.appendingPathComponent("IPOD"), cache = root.appendingPathComponent("cache")
    let device = IPodDevice(mountURL: volume)
    try FileManager.default.createDirectory(at: device.iTunesDir, withIntermediateDirectories: true)
    let url = device.iTunesDBURL
    func write(header: UInt8, body: UInt8, date: Date) throws {
        try (Data(repeating: header, count: DeviceFileCache.headerSize) + Data(repeating: body, count: 100)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    try write(header: 1, body: 1, date: date)
    #expect(try DeviceFileCache.iTunesDB(of: device, directory: cache).last == 1)

    // Same size, date and header: the Mac copy is used.
    try write(header: 1, body: 2, date: date)
    #expect(try DeviceFileCache.iTunesDB(of: device, directory: cache).last == 1)

    // A new header (db_id/hash58 change on every write): read again, old copy replaced.
    try write(header: 3, body: 3, date: date)
    #expect(try DeviceFileCache.iTunesDB(of: device, directory: cache).last == 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
}

@Test func lastITunesDBIsReadWithoutTheDevice() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbcache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let volume = root.appendingPathComponent("IPOD"), cache = root.appendingPathComponent("cache")
    let device = IPodDevice(mountURL: volume)
    try FileManager.default.createDirectory(at: device.iTunesDir, withIntermediateDirectories: true)
    try Data(repeating: 7, count: DeviceFileCache.headerSize + 10).write(to: device.iTunesDBURL)
    _ = try DeviceFileCache.iTunesDB(of: device, directory: cache)
    try FileManager.default.removeItem(at: volume)

    let offline = IPodDevice(mountURL: volume, volumeName: device.volumeName, volumeUUID: device.volumeUUID)
    #expect(DeviceFileCache.lastITunesDB(of: offline, directory: cache)?.count == DeviceFileCache.headerSize + 10)
    let other = IPodDevice(mountURL: root.appendingPathComponent("OTHER"), volumeName: "OTHER", volumeUUID: nil)
    #expect(DeviceFileCache.lastITunesDB(of: other, directory: cache) == nil)
}

/// Real iPod only: MUSICSYNC_TEST_VOLUME=/Volumes/<iPod>.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MUSICSYNC_TEST_VOLUME"] != nil))
func usbSerialOfConnectedIPod() {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUSICSYNC_TEST_VOLUME"]!)
    let serial = FirewireGuid.usbSerial(forVolume: url)
    print("[sysinfo] \(IPodDevice(mountURL: url).sysInfoExtended?.visibleBuildID ?? "nil") \(IPodDevice(mountURL: url).modelName ?? "nil")")
    print("[usbProduct] \(FirewireGuid.usbProductID(forVolume: url).map { String($0, radix: 16) } ?? "nil")")
    print("[usbSerial] \(serial ?? "nil")")
    #expect(serial.flatMap(FirewireGuid.parse) != nil)
}

@Test func modelFromUSBProductAndSize() {
    #expect(IPodDevice.modelName(usbProductID: 0x1261, capacityBytes: 159_000_000_000) == "iPod classic 160GB")
    #expect(IPodDevice.modelName(usbProductID: 0x1261, capacityBytes: 119_000_000_000) == "iPod classic 120GB (2008)")
    #expect(IPodDevice.modelName(usbProductID: 0x1261, capacityBytes: 79_000_000_000) == "iPod classic 80GB (2007)")
    #expect(IPodDevice.modelName(usbProductID: 0x9999, capacityBytes: 1) == nil)
}

@Test func modelFromSerialSuffix() {
    #expect(IPodDevice.modelName(forSerial: "8K147A059ZS") == "iPod classic 160GB (2009)")
    #expect(IPodDevice.modelName(forSerial: "XXXXXXXXQQQ") == nil)
}
