import CryptoKit
import Foundation
import Support

/// Mac copy of the iPod's iTunesDB for browsing: the slow iPod disk is read in full only after the file changed.
/// Not for writing: the sync engine reads the device file itself.
public enum DeviceFileCache {
    public static let headerSize = 0xF4

    public static var standardDirectory: URL { Paths.caches("device-db") }

    /// The iTunesDB bytes, from the cache when size, date and header (with db_id and hash58) are unchanged.
    public static func iTunesDB(of device: IPodDevice, directory: URL = standardDirectory) throws -> Data {
        let url = device.iTunesDBURL
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: headerSize) ?? Data()
        try? handle.close()

        let prefix = hash(Data((device.volumeUUID ?? device.mountURL.path).utf8))
        let stamp = "\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let cached = directory.appendingPathComponent("\(prefix)-\(hash(Data(stamp.utf8) + header))")
        if let data = try? Data(contentsOf: cached) { return data }

        let data = try Data(contentsOf: url)
        // Store only a consistent read: the file did not change between the header and the full read.
        guard data.prefix(headerSize) == header else { return data }
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where old.hasPrefix(prefix + "-") {
            try? fm.removeItem(at: directory.appendingPathComponent(old))
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.atomicWrite(data, to: cached)
        return data
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public extension IPodDevice {
    /// Stops Spotlight from indexing the iPod: indexing keeps the slow disk busy. Errors are ignored.
    func disableSpotlight() {
        let marker = mountURL.appendingPathComponent(".metadata_never_index")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }
}
