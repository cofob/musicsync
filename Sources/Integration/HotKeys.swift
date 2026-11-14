import AppKit
import Carbon.HIToolbox

/// A key with modifiers, stored with Carbon modifier bits for `RegisterEventHotKey`.
public struct KeyCombo: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    /// The key as typed when it was recorded, e.g. "P" or "→".
    public let key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public init(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let pairs: [(NSEvent.ModifierFlags, Int)] = [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        let bits = pairs.reduce(0) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
        self.init(keyCode: UInt32(keyCode), modifiers: bits, key: Self.name(keyCode) ?? (characters ?? "").uppercased())
    }

    /// "⌃⌥⌘P", in the order macOS menus use.
    public var display: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    /// A global shortcut needs ⌘, ⌥ or ⌃ (⇧ alone would eat typed capitals), except for function keys.
    public var isValid: Bool {
        !key.isEmpty && (modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || Self.functionKeys.contains(Int(keyCode)))
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                       kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// Names of keys that type nothing readable.
    private static func name(_ code: UInt16) -> String? {
        if let i = functionKeys.firstIndex(of: Int(code)) { return "F\(i + 1)" }
        let names: [Int: String] = [kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Home: "↖", kVK_End: "↘",
                                    kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦"]
        return names[Int(code)]
    }
}

public enum HotKeyAction: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case playPause, next, previous, favorite, volumeUp, volumeDown, showWindow

    public var title: String {
        switch self {
        case .playPause: "Play/Pause"
        case .next: "Next"
        case .previous: "Previous"
        case .favorite: "Favorite Current Song"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .showWindow: "Show/Hide MusicSync"
        }
    }
}

/// Settings > Shortcuts. Off by default; one combo belongs to one action only.
public struct HotKeySettings: Codable, Equatable, Sendable {
    public var enabled = false
    public private(set) var combos: [HotKeyAction: KeyCombo] = [:]

    public init() {}

    /// Sets or clears the combo of `action`. Returns the action that had this combo before and lost it.
    @discardableResult
    public mutating func assign(_ combo: KeyCombo?, to action: HotKeyAction) -> HotKeyAction? {
        let previous = combo.flatMap { c in combos.first { $0.key != action && $0.value == c }?.key }
        if let previous { combos[previous] = nil }
        combos[action] = combo
        return previous
    }
}
