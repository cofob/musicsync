import CoreGraphics
import Foundation
import ImageIO
import Support
import Testing
@testable import Artwork

private func solid(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
}

private func thumbBytes(_ dir: URL, _ loc: ArtworkLocation) throws -> Data {
    try Data(contentsOf: dir.appendingPathComponent(loc.file)).subdata(in: Int(loc.offset)..<Int(loc.offset + loc.size))
}

@Suite struct ThumbnailTests {
    @Test(arguments: [
        (UInt8(255), UInt8(0), UInt8(0), UInt16(0xF800)),
        (UInt8(0), UInt8(255), UInt8(0), UInt16(0x07E0)),
        (UInt8(0), UInt8(0), UInt8(255), UInt16(0x001F)),
        (UInt8(255), UInt8(255), UInt8(255), UInt16(0xFFFF)),
    ])
    func solidColors(r: UInt8, g: UInt8, b: UInt8, expected: UInt16) {
        let format = ArtworkFormat.classic[0]
        let t = ThumbnailEncoder.rgb565(solid(100, 100, r: r, g: g, b: b), format: format)
        #expect(t.data.count == format.byteSize)
        #expect((t.hPad, t.vPad) == (0, 0))
        let bytes = [UInt8](t.data)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            #expect(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 == expected)
        }
        #expect(bytes[0] == UInt8(expected & 0xFF) && bytes[1] == UInt8(expected >> 8))
    }

    @Test func aspectFitPadding() {
        let format = ArtworkFormat.classic[0]  // 56x56
        let t = ThumbnailEncoder.rgb565(solid(200, 100, r: 255, g: 0, b: 0), format: format)  // fits 56x28
        #expect((t.hPad, t.vPad, t.width, t.height) == (0, 14, 56, 42))
        let px = { (row: Int) -> UInt16 in
            let o = (row * 56 + 10) * 2
            return UInt16(t.data[o]) | UInt16(t.data[o + 1]) << 8
        }
        #expect(px(13) == 0)
        #expect(px(14) == 0xF800)
        #expect(px(41) == 0xF800)
        #expect(px(42) == 0)
    }

    @Test func decodePNG() throws {
        let image = solid(8, 4, r: 1, g: 2, b: 3)
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        let decoded = try #require(ThumbnailEncoder.decode(data as Data))
        #expect((decoded.width, decoded.height) == (8, 4))
        #expect(ThumbnailEncoder.decode(Data([1, 2, 3])) == nil)
    }
}

@Suite struct ArtworkDBTests {
    @Test func roundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArtworkDB.load(artworkDirectory: dir)
        #expect(db.images.isEmpty)
        let a = try db.addImage(solid(300, 300, r: 255, g: 0, b: 0), sourceSize: 1234, songDbid: 11)
        let b = try db.addImage(solid(100, 50, r: 0, g: 0, b: 255), sourceSize: 99, songDbid: 22)
        #expect((a, b) == (100, 101))
        try db.save()

        let loaded = try ArtworkDB.load(artworkDirectory: dir)
        #expect(loaded.images == db.images)
        #expect(loaded.images.map(\.songDbid) == [11, 22])
        #expect(loaded.images.map(\.sourceSize) == [1234, 99])
        for format in ArtworkFormat.classic {
            #expect(fileSize(dir.appendingPathComponent("F\(format.id)_1.ithmb")) == 2 * format.byteSize)
        }
        #expect(loaded.images[0].locations.map(\.offset) == [0, 0, 0, 0])
        #expect(loaded.images[1].locations.map(\.offset) == ArtworkFormat.classic.map { UInt32($0.byteSize) })
        #expect(loaded.wastedFraction == 0)
        // Adding after reload continues ids and keeps old entries.
        #expect(try loaded.addImage(solid(10, 10, r: 0, g: 255, b: 0), sourceSize: 1, songDbid: 33) == 102)
        try loaded.save()
        let again = try ArtworkDB.load(artworkDirectory: dir)
        #expect(Array(again.images.prefix(2)) == db.images)
        #expect(again.images.count == 3)
    }

    @Test func foreignHeaderFieldsSurvive() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArtworkDB.load(artworkDirectory: dir)
        try db.addImage(solid(20, 20, r: 9, g: 9, b: 9), sourceSize: 5, songDbid: 1)
        try db.save()
        var bytes = try Data(contentsOf: dir.appendingPathComponent("ArtworkDB"))
        let mhii = try #require(bytes.range(of: Data("mhii".utf8))).lowerBound
        bytes = bytes.patching(UInt32(5), at: mhii + 32)  // rating
        try bytes.write(to: dir.appendingPathComponent("ArtworkDB"))

        let loaded = try ArtworkDB.load(artworkDirectory: dir)
        try loaded.addImage(solid(20, 20, r: 1, g: 1, b: 1), sourceSize: 6, songDbid: 2)
        try loaded.save()
        let out = try Data(contentsOf: dir.appendingPathComponent("ArtworkDB"))
        let first = try #require(out.range(of: Data("mhii".utf8))).lowerBound
        #expect(out[first + 32] == 5)
    }

    @Test func removeAndCompact() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArtworkDB.load(artworkDirectory: dir)
        let a = try db.addImage(solid(64, 64, r: 255, g: 0, b: 0), sourceSize: 1, songDbid: 1)
        try db.addImage(solid(64, 64, r: 0, g: 255, b: 0), sourceSize: 2, songDbid: 2)
        let before = try db.images[1].locations.map { try thumbBytes(dir, $0) }
        db.removeImage(id: a)
        #expect(abs(db.wastedFraction - 0.5) < 0.001)

        try db.compact()
        // Old files are untouched until ArtworkDB is replaced.
        for format in ArtworkFormat.classic {
            #expect(fileSize(dir.appendingPathComponent("F\(format.id)_1.ithmb")) == 2 * format.byteSize)
            #expect(fileSize(dir.appendingPathComponent("F\(format.id)_1.ithmb.musicsync-new")) == format.byteSize)
        }
        try db.save(compactingAbove: nil)
        #expect(db.wastedFraction == 0)
        for format in ArtworkFormat.classic {
            #expect(fileSize(dir.appendingPathComponent("F\(format.id)_1.ithmb")) == format.byteSize)
        }
        let after = try db.images[0].locations.map { try thumbBytes(dir, $0) }
        #expect(after == before)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("F1060_1.ithmb.musicsync-new").path))
        let loaded = try ArtworkDB.load(artworkDirectory: dir)
        #expect(loaded.images == db.images)
        #expect(loaded.images[0].locations.allSatisfy { $0.offset == 0 })
    }

    /// Two images, the first removed; returns the compacted-but-not-saved database and the old ArtworkDB bytes.
    private func compactedButNotSaved(_ dir: URL) throws -> (db: ArtworkDB, oldDB: Data, keep: [Data]) {
        let db = try ArtworkDB.load(artworkDirectory: dir)
        let a = try db.addImage(solid(64, 64, r: 255, g: 0, b: 0), sourceSize: 1, songDbid: 1)
        try db.addImage(solid(64, 64, r: 0, g: 255, b: 0), sourceSize: 2, songDbid: 2)
        try db.save(compactingAbove: nil)
        let oldDB = try Data(contentsOf: dir.appendingPathComponent("ArtworkDB"))
        db.removeImage(id: a)
        let keep = try db.images[0].locations.map { try thumbBytes(dir, $0) }
        try db.compact()
        return (db, oldDB, keep)
    }

    @Test func crashBeforeArtworkDBWriteKeepsOldStateAndDropsTempFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, oldDB, _) = try compactedButNotSaved(dir)  // "crash": save() never runs
        let loaded = try ArtworkDB.load(artworkDirectory: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("ArtworkDB")) == oldDB)
        #expect(loaded.images.count == 2)
        for image in loaded.images { for loc in image.locations { #expect(try thumbBytes(dir, loc).count == Int(loc.size)) } }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".musicsync-new") }
        #expect(leftovers.isEmpty)
    }

    @Test func crashAfterArtworkDBWriteFinishesTheSwapOnLoad() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (db, _, keep) = try compactedButNotSaved(dir)
        // "Crash" between the ArtworkDB replace and the renames: write the new ArtworkDB only.
        let content = ArtworkDBContent(images: db.images, rawHeaders: [:], nextId: 200)
        try FileManager.default.atomicWrite(ArtworkDBCodec.serialize(content, formats: db.formats), to: dir.appendingPathComponent("ArtworkDB"))
        let loaded = try ArtworkDB.load(artworkDirectory: dir)
        #expect(loaded.images.count == 1)
        #expect(try loaded.images[0].locations.map { try thumbBytes(dir, $0) } == keep)
        #expect(loaded.wastedFraction == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".musicsync-new") }.isEmpty)
    }

    @Test func saveCompactsAboveThreshold() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArtworkDB.load(artworkDirectory: dir)
        let a = try db.addImage(solid(8, 8, r: 1, g: 1, b: 1), sourceSize: 1, songDbid: 1)
        try db.addImage(solid(8, 8, r: 2, g: 2, b: 2), sourceSize: 2, songDbid: 2)
        db.removeImage(id: a)
        try db.save()
        #expect(db.wastedFraction == 0)
    }

    @Test func rollover() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArtworkDB.load(artworkDirectory: dir, maxFileSize: 7000)
        for i in 0..<3 { try db.addImage(solid(16, 16, r: UInt8(i), g: 0, b: 0), sourceSize: 1, songDbid: UInt64(i)) }
        try db.save()
        let files = { (id: Int) in db.images.map { $0.locations.first { $0.formatId == id }!.file } }
        // 56x56 thumbs (6272 B) fit twice below the 7000 B limit; bigger formats roll over per image.
        #expect(files(1061) == ["F1061_1.ithmb", "F1061_1.ithmb", "F1061_2.ithmb"])
        #expect(files(1060) == ["F1060_1.ithmb", "F1060_2.ithmb", "F1060_3.ithmb"])
        let loaded = try ArtworkDB.load(artworkDirectory: dir, maxFileSize: 7000)
        #expect(loaded.images == db.images)
    }
}

@Suite struct LayoutTests {
    @Test func headerLayoutMatchesLibgpod() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try ArtworkDB.load(artworkDirectory: dir)
        try db.addImage(solid(32, 32, r: 1, g: 2, b: 3), sourceSize: 7, songDbid: 0x1122334455667788)
        try db.save()
        let data = try Data(contentsOf: dir.appendingPathComponent("ArtworkDB"))
        let r = BinaryReader(data)
        #expect(try r.tag(at: 0) == "mhfd")
        #expect(try r.u32(at: 4) == 0x84)
        #expect(try r.u32(at: 8) == UInt32(data.count))
        #expect(try r.u32(at: 16) == 2)  // unknown2
        #expect(try r.u32(at: 20) == 3)  // children
        #expect(try r.u32(at: 28) == 101)  // next id
        // mhsd 1 -> mhli -> mhii
        #expect(try r.tag(at: 0x84) == "mhsd" && r.u32(at: 0x84 + 4) == 0x60 && r.u16(at: 0x84 + 12) == 1)
        let mhli = 0x84 + 0x60
        #expect(try r.tag(at: mhli) == "mhli" && r.u32(at: mhli + 4) == 0x5c && r.u32(at: mhli + 8) == 1)
        let mhii = mhli + 0x5c
        #expect(try r.tag(at: mhii) == "mhii" && r.u32(at: mhii + 4) == 0x98)
        #expect(try r.u32(at: mhii + 12) == 4 && r.u32(at: mhii + 16) == 100)
        #expect(try r.u64(at: mhii + 20) == 0x1122334455667788 && r.u32(at: mhii + 48) == 7)
        // mhod type 2 -> mhni -> mhod type 3 with ":F1061_1.ithmb"
        let mhod = mhii + 0x98
        #expect(try r.tag(at: mhod) == "mhod" && r.u32(at: mhod + 4) == 24 && r.u16(at: mhod + 12) == 2)
        let mhni = mhod + 24
        #expect(try r.tag(at: mhni) == "mhni" && r.u32(at: mhni + 4) == 0x4c && r.u32(at: mhni + 12) == 1)
        #expect(try r.u32(at: mhni + 16) == 1061 && r.u32(at: mhni + 24) == 6272)
        let name = mhni + 0x4c
        #expect(try r.tag(at: name) == "mhod" && r.u16(at: name + 12) == 3 && r.u8(at: name + 28) == 2)
        #expect(try r.utf16le(at: name + 36, byteCount: Int(r.u32(at: name + 24))) == ":F1061_1.ithmb")
        #expect(try r.u32(at: name + 8) % 4 == 0)
        #expect(try r.u32(at: mhni + 8) == 0x4c + r.u32(at: name + 8))
        #expect(try r.u32(at: mhod + 8) == 24 + r.u32(at: mhni + 8))
    }
}
