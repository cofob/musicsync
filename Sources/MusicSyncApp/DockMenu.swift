import AppKit

/// The Dock icon menu: the current song, then playback controls. Built fresh each time it opens.
@MainActor enum DockMenu {
    static func make(_ player: Player) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let item = player.current {
            menu.addItem(info(item.title))
            if let artist = item.artist { menu.addItem(info(artist)) }
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem(player.isPlaying ? "Pause" : "Play", enabled: !player.queue.isEmpty) { player.toggle() })
        menu.addItem(ActionItem("Next", enabled: player.hasNext) { player.next() })
        menu.addItem(ActionItem("Previous", enabled: player.hasPrevious) { player.previous() })
        menu.addItem(.separator())
        let shuffle = ActionItem("Shuffle", enabled: true) { player.setShuffle(!player.shuffle) }
        shuffle.state = player.shuffle ? .on : .off
        menu.addItem(shuffle)
        return menu
    }

    private static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// Menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, enabled: Bool, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runAction() { run() }
}
