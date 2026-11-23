import SwiftUI
import Artwork
import ImageIO

/// Reads cover thumbnails of the iPod (RGB565 in `F<format>_<n>.ithmb`) on demand.
actor DeviceArtwork {
    /// Preferred format first: the biggest one.
    private static let formatOrder = [1060, 1055, 1068, 1061]

    private let directory: URL
    private let locations: [UInt32: ArtworkLocation]
    /// Mac copies of the covers (JPEG); nil reads the iPod every time.
    private let cacheDirectory: URL?
    private let cache = NSCache<NSNumber, NSImage>()
    /// Cache-only mode (iPod not connected): image id -> Mac copy.
    private var cachedFiles: [UInt32: URL] = [:]

    /// Nil when the iPod has no readable ArtworkDB or no images.
    init?(directory: URL, cacheDirectory: URL? = nil) {
        guard let db = try? ArtworkDB.load(artworkDirectory: directory) else { return nil }
        var found: [UInt32: ArtworkLocation] = [:]
        for image in db.images {
            let best = image.locations.min { Self.rank($0) < Self.rank($1) }
            if let best { found[image.id] = best }
        }
        guard !found.isEmpty else { return nil }
        self.directory = directory
        self.cacheDirectory = cacheDirectory
        locations = found
        cache.countLimit = 200
    }

    /// Covers copied to the Mac earlier; nil when there are none.
    init?(cachedIn cacheDirectory: URL) {
        var files: [UInt32: URL] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [] {
            if let id = name.split(separator: "-").first.flatMap({ UInt32($0) }) { files[id] = cacheDirectory.appendingPathComponent(name) }
        }
        guard !files.isEmpty else { return nil }
        directory = cacheDirectory
        self.cacheDirectory = cacheDirectory
        locations = [:]
        cachedFiles = files
        cache.countLimit = 200
    }

    private static func rank(_ location: ArtworkLocation) -> Int {
        formatOrder.firstIndex(of: location.formatId) ?? formatOrder.count
    }

    func image(id: UInt32) -> NSImage? {
        if let hit = cache.object(forKey: NSNumber(value: id)) { return hit }
        let file = cacheFile(id) ?? cachedFiles[id]
        let image = file.flatMap { NSImage(contentsOf: $0) } ?? readDevice(id).map { cg in
            if let file { Self.storeJPEG(cg, to: file) }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        if let image { cache.setObject(image, forKey: NSNumber(value: id)) }
        return image
    }

    /// Copies every cover to the Mac cache in disk order: one sequential pass is much faster
    /// than random reads on the iPod hard disk. Stops when the task is cancelled.
    func prefetchAll() async {
        let order = locations.sorted { ($0.value.file, $0.value.offset) < ($1.value.file, $1.value.offset) }
        for (id, _) in order {
            guard !Task.isCancelled else { return }
            if let file = cacheFile(id), !FileManager.default.fileExists(atPath: file.path), let cg = readDevice(id) {
                Self.storeJPEG(cg, to: file)
            }
            await Task.yield()  // lets `image(id:)` calls from the UI run in between
        }
    }

    /// Mac copy of one cover; the name changes when the image moves in the ithmb files.
    private func cacheFile(_ id: UInt32) -> URL? {
        guard let cacheDirectory, let l = locations[id] else { return nil }
        return cacheDirectory.appendingPathComponent("\(id)-\(l.formatId)-\(l.file.replacingOccurrences(of: ":", with: ""))-\(l.offset).jpg")
    }

    private func readDevice(_ id: UInt32) -> CGImage? {
        guard let location = locations[id],
              let format = ArtworkFormat.classic.first(where: { $0.id == location.formatId }),
              Int(location.size) == format.byteSize,
              let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(location.file)) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(location.offset))) != nil,
              let data = try? handle.read(upToCount: format.byteSize), data.count == format.byteSize else { return nil }
        return Self.decode(data, width: format.width, height: format.height)
    }

    private static func storeJPEG(_ image: CGImage, to url: URL) {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (out as Data).write(to: url, options: .atomic)
    }

    /// RGB565 little-endian (R 15-11, G 10-5, B 4-0) to RGBA.
    private static func decode(_ data: Data, width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeBytes { raw in
            for i in 0..<width * height {
                let v = UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8
                let r = UInt8(v >> 11 & 31), g = UInt8(v >> 5 & 63), b = UInt8(v & 31)
                rgba[4 * i] = r << 3 | r >> 2
                rgba[4 * i + 1] = g << 2 | g >> 4
                rgba[4 * i + 2] = b << 3 | b >> 2
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
