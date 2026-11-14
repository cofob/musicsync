import Foundation

/// Search of the Settings sidebar: a page matches when its title or one of its keywords contains every word.
public enum SettingsSearch {
    public static func matches(_ query: String, title: String, keywords: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let text = ([title] + keywords).joined(separator: " ")
        return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}

/// Settings > Advanced > Reset All Settings.
public enum SettingsReset {
    /// System keys (window frames, split views) are left alone, as are `keeping`.
    public static func reset(_ defaults: UserDefaults, keeping: Set<String>) {
        for key in defaults.dictionaryRepresentation().keys where !keeping.contains(key) && !isSystemKey(key) {
            defaults.removeObject(forKey: key)
        }
    }

    static func isSystemKey(_ key: String) -> Bool {
        ["NS", "Apple", "com.apple.", "AK", "WebKit"].contains { key.hasPrefix($0) }
    }
}
