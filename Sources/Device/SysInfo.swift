import Foundation

/// `iPod_Control/Device/SysInfo`: text file with `Key: value` lines.
public struct SysInfo: Sendable, Equatable {
    public let fields: [String: String]

    public init(fields: [String: String]) { self.fields = fields }

    public init(text: String) {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        self.init(fields: fields)
    }

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(text: String(decoding: data, as: UTF8.self))
    }

    /// Raw value, for example `xC293`.
    public var modelNumStr: String? { fields["ModelNumStr"] }
    public var firewireGuid: String? { fields["FirewireGuid"] }
    public var serialNumber: String? { fields["pszSerialNumber"] }
    public var visibleBuildID: String? { fields["visibleBuildID"] }
}

/// `iPod_Control/Device/SysInfoExtended`: XML plist.
public struct SysInfoExtended: Sendable, Equatable {
    public struct ArtworkFormat: Sendable, Equatable {
        public let formatID: Int
        public let width: Int
        public let height: Int
    }

    public var fireWireGUID: String?
    public var serialNumber: String?
    public var dbVersion: Int?
    /// Firmware version shown on the iPod, e.g. "2.0.4".
    public var visibleBuildID: String?
    public var artworkFormats: [ArtworkFormat] = []

    public init?(data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        fireWireGUID = dict["FireWireGUID"] as? String
        serialNumber = dict["SerialNumber"] as? String
        dbVersion = dict["DBVersion"] as? Int
        visibleBuildID = dict["VisibleBuildID"] as? String
        let formats = dict["AlbumArt"] as? [[String: Any]] ?? []
        artworkFormats = formats.compactMap {
            guard let id = $0["FormatId"] as? Int, let w = $0["RenderWidth"] as? Int,
                  let h = $0["RenderHeight"] as? Int else { return nil }
            return ArtworkFormat(formatID: id, width: w, height: h)
        }
    }

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }
}
