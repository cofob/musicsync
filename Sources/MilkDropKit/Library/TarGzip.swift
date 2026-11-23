import Compression
import Foundation

/// Reads a `.tar.gz` stream chunk by chunk and hands out its regular files; no external tools, so it works on iOS too.
/// Handles ustar names with a prefix and pax `path` records (GitHub archives use both).
final class TarGzip {
    private let file: (String, Data) throws -> Void
    private var filter: OutputFilter?
    private var header = Data(), headerDone = false
    private var tar = Data()
    private var pending: (name: String, size: Int, isFile: Bool)?
    private var paxPath: String?

    /// `file(path, contents)` is called for each regular file, in archive order.
    init(file: @escaping (String, Data) throws -> Void) { self.file = file }

    /// Feeds the next bytes of the gzip stream.
    func append(_ data: Data) throws {
        guard headerDone else {
            header.append(data)
            guard let start = try Self.deflateStart(header) else { return }
            headerDone = true
            filter = try OutputFilter(.decompress, using: .zlib) { [weak self] chunk in try chunk.map { try self?.untar($0) } }
            try filter?.write(header.dropFirst(start))
            header = Data()
            return
        }
        try filter?.write(data)
    }

    /// Ends the stream; the gzip trailer after the deflate data is ignored.
    func finish() throws { try filter?.finalize() }

    /// Offset of the deflate data after the gzip header, nil until the header is complete (RFC 1952).
    static func deflateStart(_ d: Data) throws -> Int? {
        let b = [UInt8](d.prefix(4096))
        guard b.count >= 10 else { return nil }
        guard b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw CocoaError(.fileReadCorruptFile) }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard b.count >= i + 2 else { return nil }; i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            guard let end = b[min(i, b.count)...].firstIndex(of: 0) else { return nil }
            i = end + 1
        }
        if flags & 2 != 0 { i += 2 }
        return b.count >= i ? i : nil
    }

    private func untar(_ chunk: Data) throws {
        tar.append(chunk)
        while true {
            if let entry = pending {
                let padded = (entry.size + 511) / 512 * 512
                guard tar.count >= padded else { return }
                let body = Data(tar.prefix(entry.size))
                tar = Data(tar.dropFirst(padded))
                pending = nil
                if entry.name == "\u{0}pax" { paxPath = Self.paxPath(body) }
                else if entry.isFile { try file(entry.name, body) }
                continue
            }
            guard tar.count >= 512 else { return }
            let block = [UInt8](tar.prefix(512))
            tar = Data(tar.dropFirst(512))
            if block.allSatisfy({ $0 == 0 }) { continue }
            let size = Int(Self.string(block[124..<136]).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = block[156]
            let prefix = Self.string(block[345..<500]), name = Self.string(block[0..<100])
            let path = paxPath ?? (prefix.isEmpty ? name : prefix + "/" + name)
            switch type {
            case UInt8(ascii: "x"): pending = ("\u{0}pax", size, false)
            case UInt8(ascii: "0"), 0: pending = (path, size, true); paxPath = nil
            default: pending = (path, size, false); if type != UInt8(ascii: "g") { paxPath = nil }
            }
        }
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// `path` of pax records like `30 path=dir/file\n`.
    private static func paxPath(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { record in
            record.split(separator: " ", maxSplits: 1).last.flatMap { $0.hasPrefix("path=") ? String($0.dropFirst(5)) : nil }
        }.first
    }
}
