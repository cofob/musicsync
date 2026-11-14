import Foundation

/// The silent sound of the page. iPhone Safari shows lock screen (and so Apple Watch) controls of a page only while
/// one of its audio elements plays, so the page loops this; the Mac plays the music.
public enum RemoteAudio {
    /// Five seconds of 8 kHz, 8-bit mono silence as WAV (about 40 KB).
    public static let silence: Data = {
        let rate: UInt32 = 8000, samples = rate * 5
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        let head = Array("RIFF".utf8) + le32(36 + samples) + Array("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
            + le32(rate) + le32(rate) + le16(1) + le16(8) + Array("data".utf8) + le32(samples)
        return Data(head + [UInt8](repeating: 128, count: Int(samples)))
    }()

    /// `body` as a whole, or the one byte range that `Range` asks for: Safari plays media only from a server that
    /// answers ranges.
    public static func ranged(_ body: Data, type: String, range: String?) -> HTTPResponse {
        var headers = [("Content-Type", type), ("Accept-Ranges", "bytes"), ("Cache-Control", "private, max-age=86400")]
        guard let range, range.hasPrefix("bytes="), !body.isEmpty else { return HTTPResponse(headers: headers, body: body) }
        let spec = range.dropFirst(6), last = body.count - 1
        let dash = spec.firstIndex(of: "-") ?? spec.endIndex
        let from = Int(spec[..<dash]), to = dash < spec.endIndex ? spec[spec.index(after: dash)...] : nil
        var bounds: (Int, Int)?
        switch (from, to) {
        case let (start?, end?) where end.isEmpty: bounds = (start, last)  // "500-"
        case let (start?, end?): if let end = Int(end), end >= start { bounds = (start, min(end, last)) }  // "0-99"
        case let (nil, end?) where spec[..<dash].isEmpty: if let n = Int(end), n > 0 { bounds = (max(0, body.count - n), last) }  // "-100"
        default: break
        }
        guard let (start, end) = bounds, start >= 0, start <= last else {
            return HTTPResponse(.rangeNotSatisfiable, headers: [("Content-Range", "bytes */\(body.count)")])
        }
        headers.append(("Content-Range", "bytes \(start)-\(end)/\(body.count)"))
        return HTTPResponse(.partialContent, headers: headers, body: body.subdata(in: start..<end + 1))
    }
}
