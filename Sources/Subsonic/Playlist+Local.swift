public extension Playlist {
    /// A playlist made on this Mac (a smart playlist), shown with the server's playlists. Read-only.
    init(localID id: String, name: String, songCount: Int?, duration: Int?, changed: String?, coverArt: String?) {
        self.init(id: id, name: name, comment: nil, owner: nil, isPublic: nil, songCount: songCount, duration: duration, created: nil,
                  changed: changed, coverArt: coverArt, readonly: true, validUntil: nil, entry: nil)
    }
}
