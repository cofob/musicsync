import AppKit

/// Space toggles playback unless text is being edited (a menu key equivalent would steal typed spaces).
@MainActor
enum SpaceKeyMonitor {
    private static let spaceKeyCode: UInt16 = 49

    /// `action` returns false when it did not use the key (e.g. nothing to play); the event then passes on.
    static func install(_ action: @escaping @MainActor () -> Bool) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isSpace = event.keyCode == spaceKeyCode
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            guard isSpace else { return event }
            let handled = MainActor.assumeIsolated {
                let responder = NSApp.keyWindow?.firstResponder
                return !(responder is NSText) && !(responder is NSButton) && action()
            }
            return handled ? nil : event
        }
    }
}
