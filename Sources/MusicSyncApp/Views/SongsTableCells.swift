import AppKit
import SwiftUI

/// AppKit cells of `SongsTable`. They are plain views placed by frame, as SwiftUI cells and Auto Layout
/// take too long when the table reloads on each typed letter.
extension SongsTable {
    /// One line of text, truncated; times and counts use even-width digits.
    final class TextCell: NSTableCellView {
        init(_ id: NSUserInterfaceItemIdentifier, digits: Bool = false) {
            super.init(frame: .zero)
            identifier = id
            let field = NSTextField.cellLabel(digits: digits)  // `textField` is weak
            addSubview(field)
            textField = field
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            textField?.frame = bounds.centeredLine(of: textField, from: 0, to: bounds.maxX - 2)
        }
    }

    /// Title, download badge and the "•••" button, which opens `menu` under itself.
    final class TitleCell: NSTableCellView {
        let badge = NSImageView()
        let more = NSButton()
        var menuItems: (() -> NSMenu?)?

        init(_ id: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            identifier = id
            let field = NSTextField.cellLabel()
            textField = field
            badge.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
            badge.contentTintColor = .secondaryLabelColor
            more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
            more.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .bold)
            more.isBordered = false
            more.target = self
            more.action = #selector(showMenu)
            for view in [field, badge, more] { addSubview(view) }
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            var right = bounds.maxX - 4
            more.frame = NSRect(x: right - 20, y: 0, width: 20, height: bounds.height)
            right -= 26
            if !badge.isHidden {
                badge.frame = NSRect(x: right - 16, y: 0, width: 16, height: bounds.height)
                right -= 22
            }
            textField?.frame = bounds.centeredLine(of: textField, from: 0, to: right)
        }

        @objc private func showMenu() {
            menuItems?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
        }
    }

    /// Five stars; a click sets the rating, a click on the current last star removes it. Empty stars show on hover only.
    final class RatingCell: NSView {
        var rating = 0 { didSet { if rating != oldValue { needsDisplay = true } } }
        var tint = NSColor.controlAccentColor { didSet { if tint != oldValue { needsDisplay = true } } }
        var onSet: ((Int) -> Void)?
        private var hovering = false { didSet { needsDisplay = true } }
        private static let size: CGFloat = 10
        private static let step = size * 1.4
        private static var images: [String: NSImage] = [:]

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
            for n in 1...5 where n <= rating || hovering {
                guard let image = star(filled: n <= rating) else { continue }
                let origin = NSPoint(x: 2 + CGFloat(n - 1) * Self.step, y: (bounds.height - image.size.height) / 2)
                image.draw(in: NSRect(origin: origin, size: image.size))
            }
        }

        /// Symbol images are made once per look; making them on each draw slows scrolling.
        private func star(filled: Bool) -> NSImage? {
            let color = filled ? tint : .tertiaryLabelColor
            let key = "\(filled) \(color)"
            if let image = Self.images[key] { return image }
            let config = NSImage.SymbolConfiguration(pointSize: Self.size, weight: .regular).applying(.init(paletteColors: [color]))
            let image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            Self.images[key] = image
            return image
        }
    }
}

private extension NSTextField {
    static func cellLabel(digits: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        if digits { field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        return field
    }
}

private extension NSRect {
    /// One text line from `minX` to `maxX`, centered vertically.
    @MainActor func centeredLine(of field: NSTextField?, from minX: CGFloat, to maxX: CGFloat) -> NSRect {
        let height = (field?.font).map { ($0.ascender - $0.descender + $0.leading).rounded(.up) + 1 } ?? 17
        return NSRect(x: minX, y: ((self.height - height) / 2).rounded(.down), width: max(0, maxX - minX), height: height)
    }
}
