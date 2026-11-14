import Foundation
import Support

/// iTunesDB gapless fields for one AAC track.
public struct GaplessInfo: Equatable, Sendable {
    public var pregap: Int
    public var postgap: Int
    public var sampleCount: Int
    public var gaplessData: Int = 0

    public init(pregap: Int, postgap: Int, sampleCount: Int, gaplessData: Int = 0) {
        self.pregap = pregap
        self.postgap = postgap
        self.sampleCount = sampleCount
        self.gaplessData = gaplessData
    }
}

/// Minimal MP4 parser that extracts gapless values from an .m4a file.
public enum Gapless {
    /// AAC-LC samples per frame.
    static let frameSize = 1024
    /// Encoder delay of Apple AAC (aac_at), used when the file has no edit list.
    static let primingSamples = 2112

    /// Reads `iTunSMPB` if present, else the `elst` edit list.
    ///
    /// ffmpeg rounds the edit-list duration up to whole frames, so its `sampleCount` is too large by up to
    /// 1023 samples. Pass `exactSampleCount` (source duration x sample rate) to get exact values.
    /// It is ignored when `iTunSMPB` provides its own count.
    public static func read(from url: URL, exactSampleCount: Int? = nil) throws -> GaplessInfo {
        try parse(Data(contentsOf: url, options: .mappedIfSafe), exactSampleCount: exactSampleCount)
    }

    public static func parse(_ data: Data, exactSampleCount: Int? = nil) throws -> GaplessInfo {
        let r = BinaryReader(data)
        let top = try boxes(r, 0..<data.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw TranscodeError.invalidMP4("no moov") }
        let moovKids = try boxes(r, moov.payload)
        if let smpb = try iTunSMPB(r, moovKids) { return smpb }

        guard let mvhd = moovKids.first(where: { $0.type == "mvhd" }),
              let trak = moovKids.first(where: { $0.type == "trak" }) else { throw TranscodeError.invalidMP4("no trak") }
        let trakKids = try boxes(r, trak.payload)
        let mdia = try child("mdia", of: trakKids, r)
        let mdiaKids = try boxes(r, mdia.payload)
        let stbl = try child("stbl", of: try boxes(r, try child("minf", of: mdiaKids, r).payload), r)
        let movieScale = try timescale(r, mvhd)
        let mediaScale = try timescale(r, try child("mdhd", of: mdiaKids, r))

        // Frames in the track; every AAC-LC frame decodes to `frameSize` samples.
        let stts = try child("stts", of: try boxes(r, stbl.payload), r)
        let entries = Int(try r.u32be(at: stts.payload.lowerBound + 4))
        let frames = try (0..<entries).reduce(0) { $0 + Int(try r.u32be(at: stts.payload.lowerBound + 8 + 8 * $1)) }
        let total = frames * frameSize

        var pregap = primingSamples  // no edit list: assume the Apple AAC encoder delay
        var count = total - pregap
        if let edts = trakKids.first(where: { $0.type == "edts" }),
           let elst = try boxes(r, edts.payload).first(where: { $0.type == "elst" }) {
            let (start, duration) = try firstEdit(r, elst)
            pregap = Int(start)  // media time is in media-timescale units (= samples for AAC)
            count = Int(duration * Int64(mediaScale) / Int64(max(movieScale, 1)))
        }
        if let exact = exactSampleCount { count = exact }
        return GaplessInfo(pregap: pregap, postgap: max(total - pregap - count, 0), sampleCount: count)
    }

    // MARK: - Boxes

    private struct Box {
        var type: String
        var payload: Range<Int>  // content after the size/type header
    }

    private static func boxes(_ r: BinaryReader, _ range: Range<Int>) throws -> [Box] {
        var out: [Box] = []
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            var size = Int(try r.u32be(at: o))
            let type = try r.tag(at: o + 4)
            var header = 8
            if size == 1 {
                size = Int(try r.u64be(at: o + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - o
            }
            guard size >= header, o + size <= range.upperBound else { throw TranscodeError.invalidMP4("bad box \(type)") }
            out.append(Box(type: type, payload: o + header..<o + size))
            o += size
        }
        return out
    }

    private static func child(_ type: String, of boxes: [Box], _ r: BinaryReader) throws -> Box {
        guard let box = boxes.first(where: { $0.type == type }) else { throw TranscodeError.invalidMP4("no \(type)") }
        return box
    }

    /// mvhd/mdhd: version+flags, then creation/modification times, then the timescale.
    private static func timescale(_ r: BinaryReader, _ box: Box) throws -> Int {
        let at = box.payload.lowerBound
        let version = try r.u8(at: at)
        return Int(try r.u32be(at: at + (version == 1 ? 20 : 12)))
    }

    /// First non-empty edit: (media_time, segment_duration).
    private static func firstEdit(_ r: BinaryReader, _ elst: Box) throws -> (Int64, Int64) {
        var o = elst.payload.lowerBound
        let version = try r.u8(at: o)
        let count = Int(try r.u32be(at: o + 4))
        o += 8
        for _ in 0..<count {
            let duration: Int64, time: Int64
            if version == 1 {
                duration = Int64(bitPattern: try r.u64be(at: o))
                time = Int64(bitPattern: try r.u64be(at: o + 8))
                o += 20
            } else {
                duration = Int64(try r.u32be(at: o))
                time = Int64(Int32(bitPattern: try r.u32be(at: o + 4)))
                o += 12
            }
            if time >= 0 { return (time, duration) }
        }
        throw TranscodeError.invalidMP4("empty elst")
    }

    // MARK: - iTunSMPB

    /// moov/udta/meta/ilst/----(mean, name "iTunSMPB", data): " 00000000 PRIMING PADDING SAMPLES ...".
    private static func iTunSMPB(_ r: BinaryReader, _ moovKids: [Box]) throws -> GaplessInfo? {
        guard let udta = moovKids.first(where: { $0.type == "udta" }),
              let meta = try boxes(r, udta.payload).first(where: { $0.type == "meta" }) else { return nil }
        // `meta` is a full box in MP4 (4 extra bytes) but a plain box in QuickTime.
        let skip = (try? r.tag(at: meta.payload.lowerBound + 4)) == "hdlr" ? 0 : 4
        let kids = try boxes(r, meta.payload.lowerBound + skip..<meta.payload.upperBound)
        guard let ilst = kids.first(where: { $0.type == "ilst" }) else { return nil }
        for item in try boxes(r, ilst.payload) where item.type == "----" {
            let parts = try boxes(r, item.payload)
            guard let name = parts.first(where: { $0.type == "name" }),
                  try r.utf8(at: name.payload.lowerBound + 4, byteCount: name.payload.count - 4) == "iTunSMPB",
                  let data = parts.first(where: { $0.type == "data" }) else { continue }
            let text = try r.utf8(at: data.payload.lowerBound + 8, byteCount: data.payload.count - 8)
            let f = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0, radix: 16) }
            guard f.count >= 4 else { continue }
            return GaplessInfo(pregap: f[1], postgap: f[2], sampleCount: f[3])
        }
        return nil
    }
}

private extension BinaryReader {
    func u32be(at o: Int) throws -> UInt32 { UInt32(bigEndian: try u32(at: o)) }
    func u64be(at o: Int) throws -> UInt64 { UInt64(bigEndian: try u64(at: o)) }
}
