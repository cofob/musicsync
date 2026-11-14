import Artwork
import CoreGraphics
import Foundation
import ITunesDB
import Subsonic

extension SyncJob {
    // MARK: Stock covers

    /// One image per album; every track of the album links to it. Albums without an image get one.
    func artworkPass() async {
        guard usesDB, let artworkDB, !plan.albumCovers.isEmpty else { return removeUnusedImages() }
        let sizes = Dictionary(artworkDB.images.map { ($0.id, $0.sourceSize) }) { a, _ in a }
        let index = Dictionary(db.tracks.enumerated().map { ($1.dbid, $0) }) { a, _ in a }
        var tracksByAlbum: [String: [Int]] = [:]
        for entry in manifest.entries.values { if let i = index[entry.dbid] { tracksByAlbum[entry.albumID, default: []].append(i) } }

        var missing: [(album: String, cover: String)] = []
        for (album, indices) in tracksByAlbum.sorted(by: { $0.key < $1.key }) where !album.isEmpty {
            if let image = manifest.artwork[album], let size = sizes[image] { link(indices, to: image, size: size) }
            else if let cover = plan.albumCovers[album] { missing.append((album, cover)) }
        }
        let covers = await fetchCovers(missing.map(\.cover), size: 320)
        for (album, cover) in missing {
            guard let data = covers[cover] else { warn("No cover for album \(album)"); continue }
            guard let image = ThumbnailEncoder.decode(data) else { warn("Unreadable cover for album \(album)"); continue }
            let indices = tracksByAlbum[album] ?? []
            guard let first = indices.first else { continue }
            do {
                let id = try artworkDB.addImage(image, sourceSize: UInt32(data.count), songDbid: db.tracks[first].dbid)
                manifest.artwork[album] = id
                link(indices, to: id, size: UInt32(data.count))
                artworkDirty = true
                manifestDirty = true
            } catch { warn("Cover for album \(album) failed: \(error.localizedDescription)") }
        }
        removeUnusedImages()
    }

    private func link(_ indices: [Int], to image: UInt32, size: UInt32) {
        for i in indices where db.tracks[i].mhiiLink != image || !db.tracks[i].hasArtwork {
            db.tracks[i].setArtwork(imageID: image, sourceSize: size)
            dbDirty = true
        }
    }

    /// Drops our images that no track references any more.
    private func removeUnusedImages() {
        guard let artworkDB else { return }
        let referenced = Set(db.tracks.map(\.mhiiLink))
        for (album, image) in manifest.artwork where !referenced.contains(image) {
            artworkDB.removeImage(id: image)
            manifest.artwork[album] = nil
            artworkDirty = true
            manifestDirty = true
        }
    }

    // MARK: Rockbox covers

    /// `cover.jpg` (500x500 baseline) next to the tracks of every Rockbox album.
    func rockboxCovers() async {
        var folders: [String: (cover: String, dir: String)] = [:]
        for entry in manifest.rockboxEntries.values {
            guard let cover = plan.albumCovers[entry.albumID] else { continue }
            let dir = (entry.relativePath as NSString).deletingLastPathComponent
            guard !FileManager.default.fileExists(atPath: device.mountURL.appendingPathComponent(dir + "/cover.jpg").path) else { continue }
            folders[dir] = (cover, dir)
        }
        let size = settings.rockboxCoverSize
        let covers = await fetchCovers(folders.values.map(\.cover), size: size)
        for (cover, dir) in folders.values {
            guard let jpeg = covers[cover].flatMap({ RockboxPaths.coverJPEG(from: $0, size: size) }) else { warn("No cover for \(dir)"); continue }
            try? jpeg.write(to: device.mountURL.appendingPathComponent(dir + "/cover.jpg"))
        }
    }

    // MARK: Download

    /// Cover bytes by cover id, 4 downloads at a time. Failures are left out.
    private func fetchCovers(_ ids: [String], size: Int) async -> [String: Data] {
        let unique = Array(Set(ids)).sorted()
        let client = self.client
        return await withTaskGroup(of: (String, Data?).self) { group in
            var next = unique.makeIterator()
            var result: [String: Data] = [:]
            func start() {
                guard !Task.isCancelled, let id = next.next() else { return }
                group.addTask { (id, await Self.coverData(client: client, id: id, size: size)) }
            }
            for _ in 0..<4 { start() }
            while let (id, data) = await group.next() {
                result[id] = data
                start()
            }
            return result
        }
    }

    private static func coverData(client: SubsonicClient, id: String, size: Int) async -> Data? {
        guard let data = try? await client.coverArt(id: id, size: size), !data.isEmpty else { return nil }
        return data
    }
}
