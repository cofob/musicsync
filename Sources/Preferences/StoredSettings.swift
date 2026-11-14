import Foundation
import Support

/// A settings struct saved as JSON under `defaultsKey` in `UserDefaults.app`.
public protocol StoredSettings: Codable, Equatable, Sendable {
    init()
    static var defaultsKey: String { get }
}

public extension StoredSettings {
    /// Saved settings, or the defaults when there are none or they are unreadable.
    static func load(from defaults: UserDefaults = .app) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(to defaults: UserDefaults = .app) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension KeyedDecodingContainer {
    /// The saved value, or `fallback` when it is missing or unreadable (for example a choice a newer version added).
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
