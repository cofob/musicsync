import AppKit
import Foundation

public struct IPodDevice: Sendable, Equatable, Identifiable {
    public let mountURL: URL
    public let volumeName: String
    public let volumeUUID: String?
    public let sysInfo: SysInfo?

    public var id: URL { mountURL }

    public var controlDir: URL { mountURL.appendingPathComponent("iPod_Control") }
    public var iTunesDir: URL { controlDir.appendingPathComponent("iTunes") }
    public var iTunesDBURL: URL { iTunesDir.appendingPathComponent("iTunesDB") }
    public var playCountsURL: URL { iTunesDir.appendingPathComponent("Play Counts") }
    public var artworkDir: URL { controlDir.appendingPathComponent("Artwork") }
    public var musicDir: URL { controlDir.appendingPathComponent("Music") }
    public var deviceDir: URL { controlDir.appendingPathComponent("Device") }
    public var musicSyncDir: URL { controlDir.appendingPathComponent("MusicSync") }

    public var sysInfoExtended: SysInfoExtended? {
        SysInfoExtended(contentsOf: deviceDir.appendingPathComponent("SysInfoExtended"))
            ?? FirewireGuid.usbSerial(forVolume: mountURL).flatMap(SysInfoExtended.readOverUSB(serial:))
    }

    public var layout: MusicLayout { MusicLayout(device: self) }

    /// Marketing name from `ModelNumStr`; nil when unknown.
    public var modelName: String? {
        Self.modelName(forModelNumStr: sysInfo?.modelNumStr) ?? Self.modelName(forSerial: sysInfoExtended?.serialNumber)
    }

    /// Last 3 serial characters -> model number (libgpod table, iPod classic only).
    private static let serialSuffixes = [
        "9ZS": "C293", "9ZU": "C297", "2C5": "B562", "2C7": "B565",
        "Y5N": "B029", "YMV": "B147", "YMU": "B145", "YMX": "B150",
    ]

    public static func modelName(forSerial serial: String?) -> String? {
        guard let serial, serial.count >= 3 else { return nil }
        return serialSuffixes[String(serial.suffix(3)).uppercased()].flatMap { models[$0] }
    }

    public var isRockboxInstalled: Bool {
        FileManager.default.fileExists(atPath: mountURL.appendingPathComponent(".rockbox").path)
    }

    /// Model number without the first letter ("xC293" and "MC293" both map to "C293").
    private static let models: [String: String] = {
        let table: [(String, [String])] = [
            ("iPod classic 160GB (2009)", ["C293", "C297"]),
            ("iPod classic 120GB", ["B562", "B565"]),
            ("iPod classic 80GB", ["B029", "B147"]),
            ("iPod classic 160GB (2007)", ["B145", "B150"]),
        ]
        return Dictionary(uniqueKeysWithValues: table.flatMap { name, keys in keys.map { ($0, name) } })
    }()

    /// Model from the USB product id and the disk size, for iPods with an empty SysInfo.
    /// All iPod classic generations share one product id, so the size tells them apart.
    public static func modelName(usbProductID: Int?, capacityBytes: Int64?) -> String? {
        let gb = capacityBytes.map { Int(($0 + 999_999_999) / 1_000_000_000) }
        switch usbProductID {
        case 0x1261:
            switch gb ?? 0 {
            case 1...80: return "iPod classic 80GB (2007)"
            case 81...120: return "iPod classic 120GB (2008)"
            case 121...160: return "iPod classic 160GB"
            default: return "iPod classic"  // storage replaced (e.g. iFlash)
            }
        case 0x1209: return "iPod (5th generation)"
        default: return nil
        }
    }

    public static func modelName(forModelNumStr str: String?) -> String? {
        guard let str, str.count >= 5 else { return nil }
        return models[String(str.uppercased().suffix(4))]
    }

    /// A device known from earlier (not connected): nothing is read from disk.
    public init(mountURL: URL, volumeName: String, volumeUUID: String?) {
        self.mountURL = mountURL
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        sysInfo = nil
    }

    public init(mountURL: URL) {
        let values = try? mountURL.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey])
        self.mountURL = mountURL
        volumeName = values?.volumeName ?? mountURL.lastPathComponent
        volumeUUID = values?.volumeUUIDString
        sysInfo = SysInfo(contentsOf: mountURL.appendingPathComponent("iPod_Control/Device/SysInfo"))
    }

    /// Returns a device when `volume` has an `iPod_Control` directory.
    public static func detect(at volume: URL) -> IPodDevice? {
        var isDir: ObjCBool = false
        let control = volume.appendingPathComponent("iPod_Control").path
        guard FileManager.default.fileExists(atPath: control, isDirectory: &isDir), isDir.boolValue else { return nil }
        return IPodDevice(mountURL: volume)
    }

    /// Total and free bytes. Plain `volumeAvailableCapacity`: removable FAT32/HFS+ has no purgeable space.
    public func capacity() throws -> (total: Int64, available: Int64) {
        let values = try mountURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity else {
            throw CocoaError(.fileReadUnknown)
        }
        return (Int64(total), Int64(free))
    }

    /// Unmounts and ejects the disk (same call Finder uses).
    public func eject() async throws {
        let url = mountURL
        try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
    }
}
