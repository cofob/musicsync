import CoreGraphics
import Foundation
import Support

/// Reads and writes `iPod_Control/Artwork/ArtworkDB` and the `F<format>_<n>.ithmb` files.
///
/// Not thread-safe: use from one task at a time.
///
/// For every track that shares an image set in the ITunesDB mhit: `artwork_count = 1`,
/// `artwork_size = sourceSize`, `has_artwork = 1`, `mhii_link = <image id returned by addImage>`.
/// Tracks without artwork keep `artwork_count = 0`, `mhii_link = 0`.
public final class ArtworkDB: @unchecked Sendable {
    public static let defaultMaxFileSize: UInt64 = 256_000_000
    public static let minimumImageId: UInt32 = 100

    public let directory: URL
    public let formats: [ArtworkFormat]
    public private(set) var images: [ArtworkImage]
    let maxFileSize: UInt64
    private var rawHeaders: [UInt32: Data]
    private var nextId: UInt32
    private var dirtyFiles: Set<String> = []
    /// Compaction state: compacted copies (`<file>.musicsync-new`) waiting to replace their ithmb files, and
    /// ithmb files with no live image. Both are applied by `save()` after ArtworkDB is written.
    private var pendingSwaps: [String] = []
    private var pendingRemovals: [String] = []
    static let tempSuffix = ".musicsync-new"

    private var dbURL: URL { directory.appendingPathComponent("ArtworkDB") }

    init(directory: URL, formats: [ArtworkFormat], maxFileSize: UInt64, content: ArtworkDBContent) {
        self.directory = directory
        self.formats = formats
        self.maxFileSize = maxFileSize
        images = content.images
        rawHeaders = content.rawHeaders
        let maxId = content.images.map(\.id).max() ?? 0
        nextId = max(Self.minimumImageId, maxId + 1, content.nextId)
    }

    /// Loads `ArtworkDB` from `artworkDirectory`; empty database if the file does not exist.
    public static func load(artworkDirectory: URL, formats: [ArtworkFormat] = ArtworkFormat.classic,
                            maxFileSize: UInt64 = defaultMaxFileSize) throws -> ArtworkDB
    {
        let url = artworkDirectory.appendingPathComponent("ArtworkDB")
        let content = FileManager.default.fileExists(atPath: url.path)
            ? try ArtworkDBCodec.parse(Data(contentsOf: url)) : ArtworkDBContent()
        recoverCompaction(in: artworkDirectory, images: content.images)
        return ArtworkDB(directory: artworkDirectory, formats: formats, maxFileSize: maxFileSize, content: content)
    }

    /// Handles `.musicsync-new` files left by a crashed compaction. The ArtworkDB was either replaced already
    /// (its thumbnails tile the temp file exactly: finish the swap) or not (the temp file is stale: delete it).
    private static func recoverCompaction(in directory: URL, images: [ArtworkImage]) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(tempSuffix) {
            let temp = directory.appendingPathComponent(name)
            let target = directory.appendingPathComponent(String(name.dropLast(tempSuffix.count)))
            let size = ((try? fm.attributesOfItem(atPath: temp.path)[.size] as? UInt64) ?? nil) ?? 0
            var slots: [UInt32: UInt32] = [:]
            for loc in images.flatMap(\.locations) where loc.file == target.lastPathComponent { slots[loc.offset] = loc.size }
            let tiles = !slots.isEmpty && UInt64(slots.values.reduce(0, +)) == size
                && slots.map({ UInt64($0.key) + UInt64($0.value) }).max() == size
            if tiles { _ = try? fm.replaceItemAt(target, withItemAt: temp) } else { try? fm.removeItem(at: temp) }
        }
    }

    // MARK: Images

    /// Writes thumbnails of all formats to the ithmb files and returns the new image id.
    @discardableResult
    public func addImage(_ image: CGImage, sourceSize: UInt32, songDbid: UInt64) throws -> UInt32 {
        guard pendingSwaps.isEmpty, pendingRemovals.isEmpty else { throw ArtworkError.corrupt("call save() after compact()") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var locations: [ArtworkLocation] = []
        for format in formats {
            let t = ThumbnailEncoder.rgb565(image, format: format)
            let (file, offset) = try append(t.data, format: format)
            locations.append(ArtworkLocation(formatId: format.id, file: file, offset: offset,
                                             size: UInt32(t.data.count), hPad: t.hPad, vPad: t.vPad,
                                             width: t.width, height: t.height))
        }
        let id = nextId
        nextId += 1
        images.append(ArtworkImage(id: id, songDbid: songDbid, sourceSize: sourceSize, locations: locations))
        return id
    }

    /// Forgets the image; its ithmb bytes stay as waste until `compact()`.
    public func removeImage(id: UInt32) {
        images.removeAll { $0.id == id }
        rawHeaders[id] = nil
    }

    /// Appends to the first `F<id>_<n>.ithmb` that is below the size limit.
    private func append(_ data: Data, format: ArtworkFormat) throws -> (file: String, offset: UInt32) {
        let fm = FileManager.default
        var index = 1
        while true {
            let file = "F\(format.id)_\(index).ithmb"
            let url = directory.appendingPathComponent(file)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size >= maxFileSize { index += 1; continue }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let offset = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            dirtyFiles.insert(file)
            return (file, UInt32(offset))
        }
    }

    // MARK: Saving

    /// Fsyncs appended ithmb data, optionally compacts, then writes ArtworkDB atomically.
    public func save(compactingAbove threshold: Double? = 0.25) throws {
        if let threshold, wastedFraction > threshold { try compact() }
        for file in dirtyFiles { try Self.fullSync(directory.appendingPathComponent(file)) }
        dirtyFiles = []
        let content = ArtworkDBContent(images: images, rawHeaders: rawHeaders, nextId: nextId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.atomicWrite(ArtworkDBCodec.serialize(content, formats: formats), to: dbURL)
        try finishCompaction()
    }

    /// Runs after the new ArtworkDB is on disk: compacted files replace the old ones, dead files go.
    private func finishCompaction() throws {
        let fm = FileManager.default
        for file in pendingSwaps {
            let target = directory.appendingPathComponent(file)
            _ = try fm.replaceItemAt(target, withItemAt: directory.appendingPathComponent(file + Self.tempSuffix))
        }
        for file in pendingRemovals { try? fm.removeItem(at: directory.appendingPathComponent(file)) }
        pendingSwaps = []
        pendingRemovals = []
    }

    private static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw CocoaError(.fileNoSuchFile) }
        defer { close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    // MARK: Compaction

    /// ithmb files present in the Artwork directory.
    func ithmbFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.range(of: #"^F\d+_\d+\.ithmb$"#, options: .regularExpression) != nil }
    }

    /// Share (0...1) of ithmb bytes not referenced by any image.
    public var wastedFraction: Double {
        let total = ithmbFiles().reduce(UInt64(0)) { sum, file in
            let url = directory.appendingPathComponent(file)
            return sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0)
        }
        guard total > 0 else { return 0 }
        let live = Set(images.flatMap(\.locations).map { Slot(file: $0.file, offset: $0.offset) })
        let sizes = Dictionary(images.flatMap(\.locations).map { (Slot(file: $0.file, offset: $0.offset), UInt64($0.size)) },
                               uniquingKeysWith: max)
        let liveBytes = live.reduce(UInt64(0)) { $0 + (sizes[$1] ?? 0) }
        return max(0, 1 - Double(liveBytes) / Double(total))
    }

    private struct Slot: Hashable { var file: String; var offset: UInt32 }

    /// Writes compacted copies of the ithmb files and updates offsets in memory. The old files stay valid until
    /// `save()` has replaced ArtworkDB; only then are they swapped. Call `save()` afterwards, and do not add images
    /// in between.
    public func compact() throws {
        var newOffsets: [Slot: UInt32] = [:]
        let byFile = Dictionary(grouping: images.flatMap(\.locations), by: \.file)
        for file in ithmbFiles() {
            let url = directory.appendingPathComponent(file)
            guard let live = byFile[file] else { pendingRemovals.append(file); continue }
            let old = try Data(contentsOf: url)
            var new = Data()
            for loc in live.sorted(by: { $0.offset < $1.offset }) where newOffsets[Slot(file: file, offset: loc.offset)] == nil {
                let end = Int(loc.offset) + Int(loc.size)
                guard end <= old.count else { throw ArtworkError.corrupt("\(file) is shorter than ArtworkDB says") }
                newOffsets[Slot(file: file, offset: loc.offset)] = UInt32(new.count)
                new += old.subdata(in: Int(loc.offset)..<end)
            }
            let temp = directory.appendingPathComponent(file + Self.tempSuffix)
            try new.write(to: temp)
            try Self.fullSync(temp)
            pendingSwaps.append(file)
            dirtyFiles.remove(file)
        }
        for i in images.indices {
            for j in images[i].locations.indices {
                let loc = images[i].locations[j]
                images[i].locations[j].offset = newOffsets[Slot(file: loc.file, offset: loc.offset)] ?? loc.offset
            }
        }
    }
}
