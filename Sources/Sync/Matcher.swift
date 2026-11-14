import Foundation
import Subsonic
import Transcode

public enum AlbumStatus: String, Sendable, CaseIterable {
    /// Not selected, not on the iPod.
    case none
    /// Selected, not on the iPod yet.
    case pending
    /// Some tracks synced.
    case partial
    case synced
    /// Synced but with an old preset.
    case outdated
    /// Present on the iPod but not put there by MusicSync (heuristic match).
    case foreign
}

/// Status of server albums against the device. Build once per device state; lookups are O(1).
public struct Matcher: Sendable {
    private struct Managed { var count = 0, outdated = false }

    private let managed: [String: Managed]
    /// artistKey + albumKey -> track counts of foreign albums.
    private let foreign: [String: [Int]]
    private let selection: Selection

    public init(library: DeviceLibrary, manifest: Manifest, selection: Selection,
                defaultPresetID: String, presets: [Preset] = Preset.builtIns) {
        self.selection = selection
        let versions = Dictionary(presets.map { ($0.id, $0.version) }) { a, _ in a }
        var managed: [String: Managed] = [:]
        let stock = manifest.entries.values.filter { library.dbids.contains($0.dbid) }
        let rockbox = manifest.rockboxEntries.values.filter { library.rockboxPaths.contains($0.relativePath) }
        for entry in stock + rockbox {
            let expected = selection.presetID(forAlbum: entry.albumID, default: defaultPresetID)
            var m = managed[entry.albumID] ?? Managed()
            m.count += 1
            if entry.presetID != expected || versions[expected].map({ $0 != entry.presetVersion }) == true { m.outdated = true }
            managed[entry.albumID] = m
        }
        self.managed = managed

        foreign = Self.foreignAlbums(library)
    }

    /// Albums on the device not put there by MusicSync: artist+album key -> track counts.
    static func foreignAlbums(_ library: DeviceLibrary) -> [String: [Int]] {
        var foreign: [String: [Int]] = [:]
        for album in library.albums where album.foreignCount > 0 {
            foreign[key(artist: album.artist, album: album.name), default: []].append(album.foreignCount)
        }
        return foreign
    }

    static func isForeign(_ foreign: [String: [Int]], artist: String, album: String, songCount: Int?) -> Bool {
        guard let counts = foreign[key(artist: artist, album: album)] else { return false }
        return songCount.map { n in counts.contains { similar($0, n) } } ?? true
    }

    static func key(artist: String, album: String) -> String { Normalizer.key(artist) + "\u{1F}" + Normalizer.key(album) }

    static func similar(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= max(2, max(a, b) / 4) }

    public func status(of album: Album) -> AlbumStatus {
        let selected = selection.selects(album)
        if let m = managed[album.id], m.count > 0 {
            if album.songCount.map({ m.count < $0 }) == true { return .partial }
            return m.outdated && selected ? .outdated : .synced
        }
        if Self.isForeign(foreign, artist: album.artistName ?? "", album: album.name, songCount: album.songCount) { return .foreign }
        return selected ? .pending : .none
    }

    public func statuses(for albums: [Album]) -> [String: AlbumStatus] {
        Dictionary(albums.map { ($0.id, status(of: $0)) }) { a, _ in a }
    }
}
