import Foundation
import Subsonic
import Support

/// The local library of one server: read API (`database`) and background sync (`mirror`).
public struct Library: Sendable {
    public let database: LibraryDatabase
    public let mirror: LibraryMirror

    public init(server: ServerConfig, settings: MirrorSettings = MirrorSettings(),
                directory: URL = Paths.appSupport("library"), coversDirectory: URL? = nil) {
        database = LibraryDatabase(serverKey: LibraryDatabase.serverKey(for: server), directory: directory, coversDirectory: coversDirectory)
        mirror = LibraryMirror(database: database, settings: settings)
    }
}
