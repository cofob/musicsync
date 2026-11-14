import Foundation
import Support

extension ITunesDB {
    /// Writes the database; with a FireWire GUID the HASH58 checksum is applied (required by the iPod classic).
    public func serialize(firewireGuid: [UInt8]? = nil) throws -> Data {
        guard playlists.first?.isMaster == true else { throw ITunesDBError.noMasterPlaylist }
        let catalog = Catalog(tracks)
        let id24 = (try? BinaryReader(header).u64(at: 0x24)) ?? 0
        let trackIDs = Set(tracks.map(\.id))

        var mhits = Data()
        for (i, track) in tracks.enumerated() {
            mhits += track.encode(albumID: catalog.albumIDs[i], artistID: catalog.artistIDs[i],
                                  composerID: catalog.composerIDs[i], dbID24: id24)
        }

        var lists = playlists
        lists[0].trackIDs = tracks.map(\.id)
        for i in lists.indices.dropFirst() { lists[i].trackIDs.removeAll { !trackIDs.contains($0) } }
        let master = lists.map { PlaylistEncoder(playlist: $0, tracks: $0.isMaster ? tracks : []) }
        let encoded = master.map { $0.encode() }
        let standard = Self.list("mhlp", encoded)
        let podcast = Self.list("mhlp", zip(master, encoded).map { $0.playlist.raw?.podcastForm ?? $1 })

        func raw(_ type: UInt32, empty: String) -> Data {
            sections.first { $0.type == type }?.data ?? Self.section(type, Self.list(empty, []))
        }
        var body = Data()
        body += Self.section(1, Self.list("mhlt", [], count: tracks.count) + mhits)
        body += Self.section(3, podcast)
        body += Self.section(2, standard)
        body += Self.section(4, Self.list("mhla", catalog.albums.map(Self.encode)))
        body += Self.section(8, Self.list("mhli", catalog.artists.map(Self.encode)))
        body += raw(6, empty: "mhlt") + raw(10, empty: "mhlt") + raw(5, empty: "mhlp")
        let known: Set<UInt32> = [1, 2, 3, 4, 5, 6, 8, 10]
        for section in sections where !known.contains(section.type) { body += section.data }
        let sectionCount = 8 + sections.filter { !known.contains($0.type) }.count

        var out = BinaryWriter()
        out.bytes(headerBytes(sectionCount: sectionCount))
        out.bytes(body)
        out.patchU32(UInt32(out.count), at: 8)
        var data = out.data
        if let firewireGuid { Hash58.sign(&data, guid: firewireGuid) }
        return data
    }

    /// The mhbd header with regenerated counts and the checksum fields cleared.
    private func headerBytes(sectionCount: Int) -> Data {
        var w = BinaryWriter()
        w.bytes(header)
        w.pad(toCount: Layout.headerLength)
        let version = (try? BinaryReader(header).u32(at: 0x10)) ?? 0
        w.patch(UInt32(w.count), at: 4)
        w.patch(max(version, Layout.version), at: 0x10)
        w.patch(UInt32(sectionCount), at: 0x14)
        // hashing scheme, unk_0x32, hash58, hash72 and hashAB areas
        for range in [0x30..<0x46, 0x58..<0x6C, 0x70..<0xA0, 0xAA..<Layout.headerLength] { w.zero(range) }
        return w.data
    }

    // MARK: - Containers

    /// `mhsd` wrapper (96-byte header).
    private static func section(_ type: UInt32, _ body: Data) -> Data {
        var w = BinaryWriter()
        w.tag("mhsd"); w.u32(96); w.u32(UInt32(96 + body.count)); w.u32(type); w.zeros(80)
        w.bytes(body)
        return w.data
    }

    /// `mhlt`/`mhlp`/`mhla`/`mhli` header (92 bytes) followed by `items`.
    private static func list(_ tag: String, _ items: [Data], count: Int? = nil) -> Data {
        var w = BinaryWriter()
        w.tag(tag); w.u32(92); w.u32(UInt32(count ?? items.count)); w.zeros(80)
        items.forEach { w.bytes($0) }
        return w.data
    }

    // MARK: - Albums and artists

    private static func encode(_ entry: Catalog.Entry) -> Data {
        var w = BinaryWriter()
        let t = entry.track
        var mhods: [Data] = []
        let isAlbum = !entry.isArtist
        if isAlbum {
            mhods.append(Mhod.string(Mhod.Kind.albumName, t.album))
            if let owner = [t.albumArtist, t.artist].first(where: { !$0.isEmpty }) { mhods.append(Mhod.string(Mhod.Kind.albumOwner, owner)) }
            if let sort = [t.sortAlbumArtist, t.sortArtist].first(where: { !$0.isEmpty }) { mhods.append(Mhod.string(Mhod.Kind.albumSortOwner, sort)) }
        } else {
            mhods.append(Mhod.string(Mhod.Kind.artistName, t.artist))
        }
        let headerLength = isAlbum ? 88 : 80
        w.tag(isAlbum ? "mhia" : "mhii"); w.u32(UInt32(headerLength)); w.u32(UInt32(headerLength + mhods.reduce(0) { $0 + $1.count }))
        w.u32(UInt32(mhods.count)); w.u32(entry.id); w.u64(entry.sqlID); w.u32(2)
        w.pad(toCount: headerLength)
        mhods.forEach { w.bytes($0) }
        return w.data
    }

    /// Album, artist and composer ids assigned in track order (id 0 = none).
    private struct Catalog {
        struct Entry {
            let id: UInt32
            let sqlID: UInt64
            let track: Track
            let isArtist: Bool
        }

        /// Hands out ids 1, 2, ... per distinct key.
        struct Table {
            var ids: [String: UInt32] = [:]
            var entries: [Entry] = []

            mutating func id(_ value: String, key: String, track: Track, isArtist: Bool) -> UInt32 {
                guard !value.isEmpty else { return 0 }
                if let id = ids[key] { return id }
                let id = UInt32(ids.count + 1)
                ids[key] = id
                entries.append(Entry(id: id, sqlID: stableHash(key), track: track, isArtist: isArtist))
                return id
            }
        }

        var albums: [Entry], artists: [Entry]
        var albumIDs: [UInt32] = [], artistIDs: [UInt32] = [], composerIDs: [UInt32] = []

        init(_ tracks: [Track]) {
            var albumTable = Table(), artistTable = Table(), composerTable = Table()
            for t in tracks {
                let owner = t.albumArtist.isEmpty ? t.artist : t.albumArtist
                albumIDs.append(albumTable.id(t.album, key: t.album + "\u{0}" + owner, track: t, isArtist: false))
                artistIDs.append(artistTable.id(t.artist, key: t.artist, track: t, isArtist: true))
                composerIDs.append(composerTable.id(t.composer, key: t.composer, track: t, isArtist: false))
            }
            albums = albumTable.entries
            artists = artistTable.entries
        }
    }
}

// MARK: - Playlists

private struct PlaylistEncoder {
    let playlist: Playlist
    /// Library tracks; non-empty only for the master playlist (used for the sort indexes).
    let tracks: [Track]

    func encode() -> Data {
        let isMaster = playlist.isMaster
        var mhods = [Mhod.string(Mhod.Kind.title, playlist.name)]
        mhods += playlist.raw?.mhods ?? [Mhod.playlistPrefs()]
        if isMaster && !tracks.isEmpty { mhods += indexes() }

        var mhips = Data()
        for (position, id) in playlist.trackIDs.enumerated() {
            var w = BinaryWriter()
            w.tag("mhip"); w.u32(76); w.u32(76 + 44); w.u32(1); w.u32(0); w.u32(0); w.u32(id); w.zeros(48)
            w.bytes(Mhod.position(UInt32(position)))
            mhips += w.data
        }

        var w = BinaryWriter()
        if let raw = playlist.raw {
            w.bytes(raw.header)
        } else {
            w.tag("mhyp"); w.u32(108); w.zeros(100)
            w.patch(UInt8(isMaster ? 1 : 0), at: 0x14)
            w.patch(MacTime.mac(playlist.timestamp ?? Date()), at: 0x18)
            w.patch(playlist.persistentId, at: 0x1C)
            w.patch(UInt16(1), at: 0x28)
            w.patch(UInt32(1), at: 0x2C)  // manual sort order
        }
        w.patch(UInt32(mhods.count), at: 0x0C)
        w.patch(UInt32(playlist.trackIDs.count), at: 0x10)
        for chunk in mhods { w.bytes(chunk) }
        w.bytes(mhips)
        w.patch(UInt32(w.count), at: 8)
        return w.data
    }

    // MARK: Sort indexes (mhod 52/53)

    private struct Key {
        let index: Int
        let title: String, album: String, artist: String, genre: String, composer: String
        let disc: Int, track: Int
        let letters: (title: UInt16, album: UInt16, artist: UInt16, genre: UInt16, composer: UInt16)
    }

    private func indexes() -> [Data] {
        let keys = tracks.enumerated().map { Self.key($1, index: $0) }
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a < b ? -1 : a > b ? 1 : 0 }
        func first(_ results: Int...) -> Int { results.first { $0 != 0 } ?? 0 }
        let tail: (Key, Key) -> Int = { first(cmp($0.disc, $1.disc), cmp($0.track, $1.track), cmp($0.title, $1.title)) }

        let specs: [(type: UInt32, compare: (Key, Key) -> Int, letter: (Key) -> UInt16)] = [
            (0x03, { first(cmp($0.title, $1.title)) }, { $0.letters.title }),
            (0x05, { first(cmp($0.artist, $1.artist), cmp($0.album, $1.album), tail($0, $1)) }, { $0.letters.artist }),
            (0x04, { first(cmp($0.album, $1.album), tail($0, $1)) }, { $0.letters.album }),
            (0x07, { first(cmp($0.genre, $1.genre), cmp($0.artist, $1.artist), cmp($0.album, $1.album), tail($0, $1)) }, { $0.letters.genre }),
            (0x12, { first(cmp($0.composer, $1.composer), cmp($0.album, $1.album), tail($0, $1)) }, { $0.letters.composer }),
        ]
        return specs.flatMap { spec in
            let order = keys.sorted { a, b in
                let c = spec.compare(a, b)
                return c != 0 ? c < 0 : a.index < b.index
            }.map(\.index)
            return Mhod.libraryIndex(sortType: spec.type, order: order, letters: keys.map(spec.letter))
        }
    }

    private static func key(_ t: Track, index: Int) -> Key {
        func pick(_ sort: String, _ plain: String) -> String { sort.isEmpty ? plain : sort }
        var artist = pick(t.sortArtist, t.artist)
        if t.sortArtist.isEmpty, t.artist.lowercased().hasPrefix("the ") { artist = String(t.artist.dropFirst(4)) + ", The" }
        let title = pick(t.sortTitle, t.title), album = pick(t.sortAlbum, t.album)
        return Key(index: index, title: collate(title), album: collate(album), artist: collate(artist),
                   genre: collate(t.genre), composer: collate(t.composer),
                   disc: Int(t.discNumber), track: Int(t.trackNumber),
                   letters: (jumpLetter(title), jumpLetter(album), jumpLetter(artist), jumpLetter(t.genre), jumpLetter(t.composer)))
    }

    private static func collate(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// First character of the sort key, upper-cased; digits and symbols map to "0".
    private static func jumpLetter(_ s: String) -> UInt16 {
        guard let scalar = collate(s).unicodeScalars.first, scalar.properties.isAlphabetic else { return 0x30 }
        return String(scalar).uppercased().utf16.first ?? 0x30
    }
}
