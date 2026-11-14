import AppKit
import Integration
import Support

/// Global shortcuts (Settings > Shortcuts). Never registered by demo or screenshot runs: they are system-wide
/// and would take the keys from the owner's session.
extension SystemServices {
    static var mayRegisterHotKeys: Bool { !Paths.isDemo && Shot.output == nil }

    func applyHotKeys() {
        guard Self.mayRegisterHotKeys else { return }
        guard hotKeys.enabled, !hotKeys.combos.isEmpty else {
            hotKeyCenter?.unregisterAll()
            takenHotKeys = []
            return
        }
        let center = hotKeyCenter ?? HotKeyCenter { [weak self] in self?.perform($0) }
        hotKeyCenter = center
        takenHotKeys = center.register(hotKeys.combos)
    }

    private func perform(_ action: HotKeyAction) {
        let player = app.player
        switch action {
        case .playPause: player.toggle()
        case .next: player.next()
        case .previous: player.previous()
        case .favorite: if let song = currentSong { app.toggleStar(song) }
        case .volumeUp: player.volume = min(1, player.volume + 0.1)
        case .volumeDown: player.volume = max(0, player.volume - 0.1)
        case .showWindow: toggleMainWindow()
        }
    }

    /// Hides the app when its window is in front, else brings the window back (or opens a new one).
    private func toggleMainWindow() {
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(MainWindow.id) == true && ($0.isVisible || $0.isMiniaturized) }
        if NSApp.isActive, window?.isKeyWindow == true { return NSApp.hide(nil) }
        NSApp.activate()
        guard let window else { return openMainWindow?() ?? () }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
