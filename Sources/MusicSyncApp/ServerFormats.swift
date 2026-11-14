import Foundation
import Observation
import Subsonic

/// The conversions the current server makes, probed once per server when a quality setting shows.
@MainActor @Observable
final class ServerFormats {
    static let shared = ServerFormats()

    /// Nil while unknown: then every choice stays on.
    private(set) var formats: Set<String>?
    @ObservationIgnored private var probed: URL?

    /// False only when the probe found that the server does not convert to `format` ("raw" is always fine).
    func allows(_ format: String) -> Bool { format == "raw" || formats?.contains(format) != false }

    /// " This server does not convert to AAC.", or empty; added to the quality footers.
    var note: String {
        let missing = TranscodeProbe.formats.filter { !allows($0) }.map { $0.uppercased() }
        return missing.isEmpty ? "" : " This server does not convert to \(missing.joined(separator: " or "))."
    }

    func probe(_ client: SubsonicClient?) async {
        guard let client, probed != client.baseURL else { return }
        probed = client.baseURL
        formats = nil
        guard let album = try? await client.getAlbumList2(type: "newest", size: 1).first,
              let song = try? await client.getAlbum(id: album.id).song?.first else { return probed = nil }
        let found = await client.convertibleFormats(songID: song.id)
        guard probed == client.baseURL else { return }
        if found == nil { probed = nil }
        formats = found
    }
}
