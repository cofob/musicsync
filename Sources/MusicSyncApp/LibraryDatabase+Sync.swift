import Library
import Sync

extension LibraryDatabase {
    /// The mirror as a sync source: the selection is expanded from disk, the server is asked only for what is missing.
    nonisolated var local: LocalLibrary {
        LocalLibrary(album: { await self.album(id: $0) }, artistAlbumIDs: { await self.albumIDs(ofArtist: $0) },
                     playlist: { await self.playlist(id: $0) })
    }
}
