import Foundation
import Support

extension ITunesDB {
    private enum Section {
        static let tracks: UInt32 = 1, playlists: UInt32 = 2, podcasts: UInt32 = 3, albums: UInt32 = 4, artists: UInt32 = 8
    }

    public static func parse(_ data: Data) throws -> ITunesDB {
        let r = BinaryReader(data)
        guard data.count >= 0x18, (try? r.tag(at: 0)) == "mhbd" else { throw ITunesDBError.notITunesDB }
        let headerLength = try r.int(4)
        let end = min(try r.int(8), data.count)
        guard headerLength >= 0x18, headerLength <= end else { throw ITunesDBError.corrupt("mhbd header") }

        var tracks: [Track]?
        var playlists: [Playlist]?
        var podcastForms: [UInt64: Data] = [:]
        var sections: [RawSection] = []

        var offset = headerLength
        while offset + 16 <= end {
            try r.expectTag("mhsd", at: offset)
            let hl = try r.int(offset + 4), total = try r.int(offset + 8), type = try r.u32(at: offset + 12)
            guard hl >= 16, total >= hl, offset + total <= end else { throw ITunesDBError.corrupt("mhsd at \(offset)") }
            let body = offset + hl
            switch type {
            case Section.tracks: tracks = try parseTracks(r, at: body)
            case Section.playlists: playlists = try parsePlaylists(r, at: body).map(\.playlist)
            case Section.podcasts:
                // Only used to keep podcast lists intact; an unreadable section is not fatal.
                for item in (try? parsePlaylists(r, at: body)) ?? [] where item.podcast { podcastForms[item.playlist.persistentId] = item.chunk }
            case Section.albums, Section.artists: break
            default: sections.append(RawSection(type: type, data: try r.bytes(at: offset, count: total)))
            }
            offset += total
        }
        guard let tracks else { throw ITunesDBError.corrupt("no track list") }
        guard var playlists, playlists.first?.isMaster == true else { throw ITunesDBError.noMasterPlaylist }
        playlists = playlists.map { playlist in
            var playlist = playlist
            playlist.raw?.podcastForm = podcastForms[playlist.persistentId]
            return playlist
        }
        return ITunesDB(tracks: tracks, playlists: playlists, header: try r.bytes(at: 0, count: headerLength), sections: sections)
    }

    // MARK: - Tracks

    private static func parseTracks(_ r: BinaryReader, at start: Int) throws -> [Track] {
        try r.expectTag("mhlt", at: start)
        let count = try r.int(start + 8)
        var offset = start + (try r.int(start + 4))
        var tracks: [Track] = []
        for _ in 0..<count {
            try r.expectTag("mhit", at: offset)
            let hl = try r.int(offset + 4), total = try r.int(offset + 8), mhodCount = try r.int(offset + 12)
            guard hl >= 0x20, total >= hl else { throw ITunesDBError.corrupt("mhit at \(offset)") }
            let mhods = try readMhods(r, from: offset + hl, count: mhodCount, limit: offset + total)
            tracks.append(Track.decode(header: try r.bytes(at: offset, count: hl), mhods: mhods))
            offset += total
        }
        return tracks
    }

    /// Reads `count` consecutive mhod chunks.
    private static func readMhods(_ r: BinaryReader, from start: Int, count: Int, limit: Int) throws -> [Data] {
        var offset = start
        var chunks: [Data] = []
        for _ in 0..<count {
            guard offset + 12 <= limit else { break }
            try r.expectTag("mhod", at: offset)
            let length = try r.int(offset + 8)
            guard length >= 24, offset + length <= limit else { throw ITunesDBError.corrupt("mhod at \(offset)") }
            chunks.append(try r.bytes(at: offset, count: length))
            offset += length
        }
        return chunks
    }

    // MARK: - Playlists

    private typealias ParsedPlaylist = (playlist: Playlist, podcast: Bool, chunk: Data)

    private static func parsePlaylists(_ r: BinaryReader, at start: Int) throws -> [ParsedPlaylist] {
        try r.expectTag("mhlp", at: start)
        let count = try r.int(start + 8)
        var offset = start + (try r.int(start + 4))
        var result: [ParsedPlaylist] = []
        for _ in 0..<count {
            try r.expectTag("mhyp", at: offset)
            let hl = try r.int(offset + 4), total = try r.int(offset + 8)
            guard hl >= 0x30, total >= hl else { throw ITunesDBError.corrupt("mhyp at \(offset)") }
            let limit = offset + total
            let mhods = try readMhods(r, from: offset + hl, count: try r.int(offset + 12), limit: limit)
            var mhipOffset = offset + hl + mhods.reduce(0) { $0 + $1.count }

            var playlist = Playlist(name: "", isMaster: try r.u8(at: offset + 0x14) == 1)
            playlist.persistentId = try r.u64(at: offset + 0x1C)
            playlist.timestamp = MacTime.date(try r.u32(at: offset + 0x18))
            playlist.name = mhods.last { $0.mhodType == Mhod.Kind.title }.flatMap(Mhod.decodeString) ?? ""
            playlist.trackIDs = []
            for _ in 0..<(try r.int(offset + 0x10)) {
                guard mhipOffset + 0x1C <= limit else { break }
                try r.expectTag("mhip", at: mhipOffset)
                let isGroup = try r.u32(at: mhipOffset + 0x10) != 0
                if !isGroup { playlist.trackIDs.append(try r.u32(at: mhipOffset + 0x18)) }
                mhipOffset += max(try r.int(mhipOffset + 8), 0x1C)
            }
            let extras = mhods.filter { ![Mhod.Kind.title, Mhod.Kind.libraryIndex, Mhod.Kind.jumpTable].contains($0.mhodType) }
            playlist.raw = RawPlaylist(header: try r.bytes(at: offset, count: hl), mhods: extras, podcastForm: nil)
            let podcast = try r.u16(at: offset + 0x2A) != 0
            result.append((playlist, podcast, try r.bytes(at: offset, count: total)))
            offset += total
        }
        return result
    }
}
