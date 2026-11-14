import Foundation
import Subsonic

/// What is dragged inside the app. It travels as plain text, so no custom type must be declared in Info.plist.
enum DragPayload: Codable, Equatable {
    /// Songs; `index` is the row on a playlist page, for reordering.
    case songs([String], index: Int?)
    case album(String)

    private static let prefix = "musicsync-drag:"

    var text: String {
        Self.prefix + ((try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    init?(_ text: String) {
        guard text.hasPrefix(Self.prefix),
              let value = try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst(Self.prefix.count).utf8)) else { return nil }
        self = value
    }
}

extension AppModel {
    /// Song ids of dropped items, in order; albums are fetched.
    func songIds(_ payloads: [DragPayload]) async -> [String] {
        var ids: [String] = []
        for payload in payloads {
            switch payload {
            case .songs(let songs, _): ids += songs
            case .album(let id): ids += (try? await album(id))?.song?.map(\.id) ?? []
            }
        }
        return ids
    }
}
