import Foundation
import Subsonic
import Support

/// The local library of one server: read API (`database`), background sync (`mirror`) and the listening log (`history`).
public struct Library: Sendable {
    public let database: LibraryDatabase
    public let mirror: LibraryMirror
    public let history: PlayHistory

    public init(server: ServerConfig, settings: MirrorSettings = MirrorSettings(),
                directory: URL = Paths.appSupport("library"), coversDirectory: URL? = nil) {
        let key = LibraryDatabase.serverKey(for: server)
        database = LibraryDatabase(serverKey: key, directory: directory, coversDirectory: coversDirectory)
        mirror = LibraryMirror(database: database, settings: settings)
        history = PlayHistory(serverKey: key, directory: directory)
    }
}
