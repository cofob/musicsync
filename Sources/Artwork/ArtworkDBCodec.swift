import Foundation
import Support

public enum ArtworkError: Error, Equatable {
    case corrupt(String)
}

/// Where one thumbnail of an image lives (one mhni entry).
public struct ArtworkLocation: Sendable, Equatable {
    public var formatId: Int
    /// File name inside the Artwork directory, e.g. `F1060_1.ithmb`.
    public var file: String
    public var offset: UInt32
    public var size: UInt32
    public var hPad: Int16
    public var vPad: Int16
    public var width: Int16
    public var height: Int16
}

/// One mhii entry.
public struct ArtworkImage: Sendable, Equatable {
    public var id: UInt32
    public var songDbid: UInt64
    public var sourceSize: UInt32
    public var locations: [ArtworkLocation]
}

/// Parsed ArtworkDB. `rawHeaders` keeps foreign mhii headers (rating, dates, unknowns) for re-writing.
struct ArtworkDBContent {
    var images: [ArtworkImage] = []
    var rawHeaders: [UInt32: Data] = [:]
    var nextId: UInt32 = 0
}

enum ArtworkDBCodec {
    static let mhfdLen = 0x84, mhsdLen = 0x60, mhlLen = 0x5c, mhiiLen = 0x98
    static let mhniLen = 0x4c, mhifLen = 0x7c, modLen = 24, modStringHeader = 36

    // MARK: Parse

    static func parse(_ data: Data) throws -> ArtworkDBContent {
        let r = BinaryReader(data)
        do {
            try r.expectTag("mhfd", at: 0)
            var content = ArtworkDBContent()
            content.nextId = try r.u32(at: 28)
            var pos = Int(try r.u32(at: 4))
            for _ in 0..<(try r.u32(at: 20)) {
                try r.expectTag("mhsd", at: pos)
                let hlen = Int(try r.u32(at: pos + 4)), total = Int(try r.u32(at: pos + 8))
                if try r.u16(at: pos + 12) == 1 { try parseImageList(r, at: pos + hlen, into: &content) }
                guard total >= hlen, total > 0 else { throw ArtworkError.corrupt("mhsd length") }
                pos += total
            }
            return content
        } catch let error as BinaryError {
            throw ArtworkError.corrupt("\(error)")
        }
    }

    private static func parseImageList(_ r: BinaryReader, at start: Int, into content: inout ArtworkDBContent) throws {
        try r.expectTag("mhli", at: start)
        var pos = start + Int(try r.u32(at: start + 4))
        for _ in 0..<(try r.u32(at: start + 8)) {
            try r.expectTag("mhii", at: pos)
            let hlen = Int(try r.u32(at: pos + 4)), total = Int(try r.u32(at: pos + 8))
            guard hlen >= 0x34, total >= hlen else { throw ArtworkError.corrupt("mhii length") }
            var image = ArtworkImage(id: try r.u32(at: pos + 16), songDbid: try r.u64(at: pos + 20),
                                     sourceSize: try r.u32(at: pos + 48), locations: [])
            var child = pos + hlen
            for _ in 0..<(try r.u32(at: pos + 12)) {
                let childTotal = Int(try r.u32(at: child + 8))
                if try r.u16(at: child + 12) == 2 {
                    image.locations.append(try parseLocation(r, at: child + Int(try r.u32(at: child + 4))))
                }
                guard childTotal > 0 else { throw ArtworkError.corrupt("mhod length") }
                child += childTotal
            }
            content.rawHeaders[image.id] = try r.bytes(at: pos, count: hlen)
            content.images.append(image)
            pos += total
        }
    }

    private static func parseLocation(_ r: BinaryReader, at p: Int) throws -> ArtworkLocation {
        try r.expectTag("mhni", at: p)
        let hlen = Int(try r.u32(at: p + 4))
        var file = ""
        if try r.u32(at: p + 12) > 0 {
            let s = p + hlen  // mhod type 3
            let byteCount = Int(try r.u32(at: s + 24))
            let raw = try r.bytes(at: s + modStringHeader, count: byteCount)
            let encoding: String.Encoding = try r.u8(at: s + 28) == 2 ? .utf16LittleEndian : .utf8
            file = String(data: raw, encoding: encoding) ?? ""
            file = String(file.split(separator: ":").last ?? "")
        }
        return ArtworkLocation(formatId: Int(try r.u32(at: p + 16)), file: file, offset: try r.u32(at: p + 20),
                               size: try r.u32(at: p + 24), hPad: try r.i16(at: p + 30), vPad: try r.i16(at: p + 28),
                               width: try r.i16(at: p + 34), height: try r.i16(at: p + 32))
    }

    // MARK: Serialize

    static func serialize(_ content: ArtworkDBContent, formats: [ArtworkFormat]) -> Data {
        var w = BinaryWriter()
        block(&w, "mhfd", mhfdLen) { w in
            w.u32(0); w.u32(2); w.u32(3); w.u32(0); w.u32(content.nextId)
            w.pad(toCount: 48); w.u8(2)  // flag1
        } children: { w in
            block(&w, "mhsd", mhsdLen) { w in w.u16(1); w.u16(0) } children: { w in
                block(&w, "mhli", mhlLen, hasTotal: false) { w in w.u32(UInt32(content.images.count)) } children: { w in
                    for image in content.images { writeImage(&w, image, raw: content.rawHeaders[image.id]) }
                }
            }
            block(&w, "mhsd", mhsdLen) { w in w.u16(2); w.u16(0) } children: { w in
                block(&w, "mhla", mhlLen, hasTotal: false) { w in w.u32(0) }
            }
            block(&w, "mhsd", mhsdLen) { w in w.u16(3); w.u16(0) } children: { w in
                block(&w, "mhlf", mhlLen, hasTotal: false) { w in w.u32(UInt32(formats.count)) } children: { w in
                    for f in formats {
                        block(&w, "mhif", mhifLen) { w in w.u32(0); w.u32(UInt32(f.id)); w.u32(UInt32(f.byteSize)) }
                    }
                }
            }
        }
        return w.data
    }

    /// Writes tag + header length (+ total length placeholder), `fields`, zero padding to the
    /// header length, then `children`, and finally patches the total length.
    private static func block(_ w: inout BinaryWriter, _ tag: String, _ headerLen: Int, hasTotal: Bool = true,
                              fields: (inout BinaryWriter) -> Void = { _ in },
                              children: (inout BinaryWriter) -> Void = { _ in })
    {
        let start = w.count
        w.tag(tag)
        w.u32(UInt32(headerLen))
        if hasTotal { w.u32(0) }
        fields(&w)
        w.pad(toCount: start + headerLen)
        children(&w)
        if hasTotal { w.patchU32(UInt32(w.count - start), at: start + 8) }
    }

    private static func writeImage(_ w: inout BinaryWriter, _ image: ArtworkImage, raw: Data?) {
        let start = w.count
        var header = raw ?? (Data("mhii".utf8) + Data(count: mhiiLen - 4)).patching(UInt32(mhiiLen), at: 4)
        header = header.patching(UInt32(image.locations.count), at: 12).patching(image.id, at: 16)
            .patching(image.songDbid, at: 20).patching(image.sourceSize, at: 48)
        w.bytes(header)
        for loc in image.locations {
            block(&w, "mhod", modLen) { w in w.u16(2); w.u16(0); w.u32(0); w.u32(0) } children: { w in
                block(&w, "mhni", mhniLen) { w in
                    w.u32(1); w.u32(UInt32(loc.formatId)); w.u32(loc.offset); w.u32(loc.size)
                    w.i16(loc.vPad); w.i16(loc.hPad); w.i16(loc.height); w.i16(loc.width)
                } children: { w in writeFileName(&w, ":" + loc.file) }
            }
        }
        w.patchU32(UInt32(w.count - start), at: start + 8)
    }

    /// mhod type 3: UTF-16LE string, total length aligned to 4.
    private static func writeFileName(_ w: inout BinaryWriter, _ name: String) {
        let utf16 = name.data(using: .utf16LittleEndian) ?? Data()
        let padding = (4 - (modStringHeader + utf16.count) % 4) % 4
        let start = w.count
        w.tag("mhod")
        w.u32(UInt32(modLen))
        w.u32(UInt32(modStringHeader + utf16.count + padding))
        w.u16(3); w.u8(0); w.u8(UInt8(padding))
        w.u32(0); w.u32(0)
        w.u32(UInt32(utf16.count))
        w.u8(2); w.u8(0); w.u16(0); w.u32(0)
        w.bytes(utf16)
        w.zeros(padding)
        assert(w.count - start == modStringHeader + utf16.count + padding)
    }
}
