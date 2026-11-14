import Foundation

/// Which conversions the server makes. A server without a conversion to a format sends the original file instead,
/// so the content type of a short `stream` request tells.
public enum TranscodeProbe {
    /// Formats the stream and download settings offer.
    public static let formats = ["aac", "mp3"]

    /// True when `contentType` is what a conversion to `format` sends.
    public static func matches(format: String, contentType: String?) -> Bool {
        guard let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        switch format {
        case "mp3": return ["audio/mpeg", "audio/mp3"].contains(type)
        case "aac": return ["audio/aac", "audio/aacp", "audio/mp4", "audio/x-m4a"].contains(type)
        default: return false
        }
    }
}

public extension SubsonicClient {
    /// Content type of song `id` converted to `format`; only the headers are read. Nil for an HTTP error.
    func streamContentType(id: String, format: String, maxBitRate: Int = 128) async throws -> String? {
        let (bytes, response) = try await session.bytes(from: streamURL(id: id, format: format, maxBitRate: maxBitRate))
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return http.value(forHTTPHeaderField: "Content-Type")
    }

    /// Formats of `TranscodeProbe.formats` the server converts song `id` to; nil when a request failed.
    func convertibleFormats(songID id: String) async -> Set<String>? {
        var found = Set<String>()
        for format in TranscodeProbe.formats {
            guard let type = try? await streamContentType(id: id, format: format) else { return nil }
            if TranscodeProbe.matches(format: format, contentType: type) { found.insert(format) }
        }
        return found
    }
}
