import CoreGraphics
import Foundation
import ImageIO
import Transcode
import UniformTypeIdentifiers

/// File names for Rockbox folder mode (FAT32-safe).
public enum RockboxPaths {
    public static let maxComponentBytes = 255
    private static let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)

    /// Replaces forbidden characters, trims dots and spaces, cuts to `maxBytes` UTF-8 bytes.
    public static func component(_ text: String, fallback: String = "_", maxBytes: Int = maxComponentBytes) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
        let trim = CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)
        var out = "", used = 0
        for ch in cleaned.trimmingCharacters(in: trim) {
            let size = String(ch).utf8.count
            if used + size > maxBytes { break }
            out.append(ch)
            used += size
        }
        out = out.trimmingCharacters(in: trim)
        return out.isEmpty ? fallback : out
    }

    /// Rockbox MAX_PATH is 260 bytes with the NUL; the rest is room for ` (n)`.
    static let maxPathBytes = 250

    /// `Music/<AlbumArtist>/<Year> - <Album>/<DD-NN> - <Title>.<ext>`, within `maxPathBytes` with the leading `/`.
    public static func songPath(_ tags: TrackTags, ext: String) -> String {
        let artist = component(tags.albumArtist.isEmpty ? tags.artist : tags.albumArtist, fallback: "Unknown Artist", maxBytes: 80)
        let album = tags.album.isEmpty ? "Unknown Album" : tags.album
        let albumDir = component(tags.year.map { "\($0) - \(album)" } ?? album, fallback: "Unknown Album", maxBytes: 80)
        let number = String(format: "%02d-%02d", tags.discNumber ?? 1, tags.trackNumber ?? 0)
        let budget = maxPathBytes - "/Music///.".utf8.count - artist.utf8.count - albumDir.utf8.count - ext.utf8.count
        let name = component("\(number) - \(tags.title)", fallback: number, maxBytes: budget)
        return "Music/\(artist)/\(albumDir)/\(name).\(ext)"
    }

    /// `Playlists/<name>.m3u8`
    public static func playlistPath(_ name: String) -> String {
        "Playlists/\(component(name, fallback: "Playlist", maxBytes: maxComponentBytes - 5)).m3u8"
    }

    /// A distinct `Playlists/<name>.m3u8` per playlist id (` (2)`, ... for equal names, ignoring case as FAT32 does).
    /// Paths recorded for playlists outside `playlists` stay taken.
    public static func playlistPaths(for playlists: [DesiredPlaylist], recorded: [String: Manifest.RockboxPlaylist]) -> [String: String] {
        let ids = Set(playlists.map(\.id))
        var taken = Set(recorded.filter { !ids.contains($0.key) }.map { $0.value.path.lowercased() })
        var paths: [String: String] = [:]
        for p in playlists.sorted(by: { $0.id < $1.id }) {
            let base = playlistPath(p.name).dropLast(".m3u8".count)
            var path = "\(base).m3u8", n = 1
            while !taken.insert(path.lowercased()).inserted {
                n += 1
                path = "\(base) (\(n)).m3u8"
            }
            paths[p.id] = path
        }
        return paths
    }

    /// m3u8 text; paths are relative to the `Playlists` folder.
    public static func playlistContents(_ paths: [String]) -> String {
        "#EXTM3U\n" + paths.map { "../\($0)\n" }.joined()
    }

    /// Baseline JPEG, `size` x `size`, from any image data.
    public static func coverJPEG(from data: Data, size: Int = 500) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
