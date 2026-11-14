import AppKit
import SwiftUI

/// AppKit cells of `SongsTable`. They are plain views, as SwiftUI cells take too long to lay out when the
/// table reloads on each typed letter.
extension SongsTable {
    /// One line of text, truncated; times and counts use even-width digits.
    final class TextCell: NSTableCellView {
        init(_ id: NSUserInterfaceItemIdentifier, digits: Bool = false) {
            super.init(frame: .zero)
            identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if digits { field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
            textField = field
            pin(field, leading: 2, trailing: -2)
        }

        required init?(coder: NSCoder) { nil }
    }

    /// Title, download badge and the "•••" button, which opens `menu` under itself.
    final class TitleCell: NSTableCellView {
        let badge = NSImageView()
        let more = NSButton()
        var menuItems: (() -> NSMenu?)?

        init(_ id: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentHuggingPriority(.init(1), for: .horizontal)  // the "•••" stays at the right edge
            textField = field
            badge.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
            badge.contentTintColor = .secondaryLabelColor
            more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
            more.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .bold)
            more.isBordered = false
            more.target = self
            more.action = #selector(showMenu)
            let stack = NSStackView(views: [field, badge, more])
            stack.spacing = 6
            pin(stack, leading: 2, trailing: -4)
        }

        required init?(coder: NSCoder) { nil }

        @objc private func showMenu() {
            menuItems?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
        }
    }

    /// Five stars; a click sets the rating, a click on the current last star removes it. Empty stars show on hover only.
    final class RatingCell: NSView {
        var rating = 0 { didSet { needsDisplay = true } }
        var tint = NSColor.controlAccentColor
        var onSet: ((Int) -> Void)?
        private var hovering = false { didSet { needsDisplay = true } }
        private static let size: CGFloat = 10
        private static let step = size * 1.4

        init(_ id: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            identifier = id
        }

        required init?(coder: NSCoder) { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }

        override func mouseDown(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x - 2
            guard x >= 0, x < Self.step * 5 else { return super.mouseDown(with: event) }
            let n = Int(x / Self.step) + 1
            onSet?(n == rating ? 0 : n)
        }

        override func draw(_ dirtyRect: NSRect) {
            let config = NSImage.SymbolConfiguration(pointSize: Self.size, weight: .regular)
            for n in 1...5 where n <= rating || hovering {
                let filled = n <= rating
                guard let image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config.applying(.init(paletteColors: [filled ? tint : .tertiaryLabelColor]))) else { continue }
                let origin = NSPoint(x: 2 + CGFloat(n - 1) * Self.step, y: (bounds.height - image.size.height) / 2)
                image.draw(in: NSRect(origin: origin, size: image.size))
            }
        }
    }
}

private extension NSView {
    /// Fills the width and centers vertically.
    func pin(_ view: NSView, leading: CGFloat, trailing: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailing),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
