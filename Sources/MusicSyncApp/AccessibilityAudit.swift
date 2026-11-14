import AppKit
import ApplicationServices

/// Development only: the accessibility tree of the app's windows as VoiceOver gets it, for `check:accessibility`.
/// It asks through the accessibility API, as VoiceOver does: only then does SwiftUI build its elements. Calls into
/// the own process are answered on the calling thread, so they run on the main thread. That needs the
/// Accessibility permission of the process that started the app (the terminal).
@MainActor enum AccessibilityAudit {
    struct Node {
        let element: AXUIElement
        let role: String
        let subrole: String
        let label: String
        let value: String?
        let actions: [String]
        /// The window title, to tell the main window from the MiniPlayer.
        let window: String
    }

    /// Roles VoiceOver reads as a control the user presses.
    private static let pressable: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXDisclosureTriangle"]
    /// Window and scroll bar parts, which VoiceOver names by their subrole.
    private static let standard: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXFullScreenButton", "AXZoomButton",
                                                "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// All elements of the app's windows, depth first.
    static func nodes() -> [Node] {
        var out: [Node] = []
        func walk(_ e: AXUIElement, _ window: String, _ depth: Int) {
            guard depth < 100 else { return }
            var names: CFArray?
            AXUIElementCopyActionNames(e, &names)
            let value = string(e, "AXValueDescription") ?? attribute(e, "AXValue").map { "\($0)" }
            out.append(Node(element: e, role: string(e, "AXRole") ?? "", subrole: string(e, "AXSubrole") ?? "",
                            label: [string(e, "AXDescription"), string(e, "AXTitle")].compactMap { $0 }.first { !$0.isEmpty } ?? "",
                            value: value, actions: names as? [String] ?? [], window: window))
            for child in attribute(e, "AXChildren") as? [AXUIElement] ?? [] { walk(child, window, depth + 1) }
        }
        for window in attribute(AXUIElementCreateApplication(getpid()), "AXWindows") as? [AXUIElement] ?? [] {
            walk(window, string(window, "AXTitle") ?? "", 0)
        }
        return out
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }

    /// Pressable elements without a label: VoiceOver would read only "button".
    static func unlabeled(_ nodes: [Node]) -> [Node] {
        nodes.filter { pressable.contains($0.role) && !standard.contains($0.subrole) && $0.label.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
