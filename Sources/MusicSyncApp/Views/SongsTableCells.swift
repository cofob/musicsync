import AppKit

/// Cells of `SongsTable`. Each one is a single view that draws itself: SwiftUI cells, Auto Layout and even text
/// fields take too long to make and lay out when a big window shows the table or it reloads on each typed letter.
extension SongsTable {
    /// One line of text, truncated. The title cell adds a gray download badge and the "•••" button,
    /// which opens `menuItems` under itself.
    final class TextCell: NSView {
        var text = "" { didSet { if text != oldValue { changed() } } }
        var color = NSColor.labelColor { didSet { if color != oldValue { needsDisplay = true } } }
        var badge: String? { didSet { if badge != oldValue { needsDisplay = true } } }
        var tint = NSColor.controlAccentColor { didSet { if tint != oldValue { needsDisplay = true } } }
        var menuItems: (() -> NSMenu?)? { didSet { if (menuItems == nil) != (oldValue == nil) { needsDisplay = true } } }
        private let font: NSFont
        private let hasMenu: Bool
        private static let menuWidth: CGFloat = 26

        init(_ id: NSUserInterfaceItemIdentifier, digits: Bool = false, menu: Bool = false) {
            font = digits ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
            hasMenu = menu
            super.init(frame: .zero)
            identifier = id
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }

        required init?(coder: NSCoder) { nil }

        private func changed() {
            setAccessibilityLabel(text)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            var right = bounds.maxX - 2
            if hasMenu {
                right = bounds.maxX - Self.menuWidth - 4
                if menuItems != nil, let more = symbol("ellipsis", size: NSFont.systemFontSize, weight: .bold, color: tint) {
                    more.draw(in: centered(more.size, x: bounds.maxX - Self.menuWidth / 2 - 4 - more.size.width / 2))
                }
            }
            if let badge, let image = symbol(badge, size: 10, color: .secondaryLabelColor) {
                right -= image.size.width
                image.draw(in: centered(image.size, x: right))
                right -= 6
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let line = (font.ascender - font.descender + font.leading).rounded(.up)
            (text as NSString).draw(with: NSRect(x: 0, y: ((bounds.height - line) / 2).rounded(.down), width: max(0, right), height: line),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }

        /// Clicks go to the table, which selects rows, except on the "•••" button.
        override func hitTest(_ point: NSPoint) -> NSView? {
            hasMenu && menuItems != nil && convert(point, from: superview).x > bounds.maxX - Self.menuWidth - 4 ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            guard let menu = menuItems?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - Self.menuWidth - 4, y: bounds.minY - 4), in: self)
        }

        private func centered(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(origin: NSPoint(x: x, y: ((bounds.height - size.height) / 2).rounded()), size: size)
        }
    }

    /// The red favorite star.
    final class StarCell: NSView {
        var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
        var tint = NSColor.controlAccentColor { didSet { if tint != oldValue { needsDisplay = true } } }

        init(_ id: NSUserInterfaceItemIdentifier) {
            super.init(frame: .zero)
            identifier = id
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard isOn, let star = symbol("star.fill", size: 12, color: tint) else { return }
            star.draw(in: NSRect(origin: NSPoint(x: ((bounds.width - star.size.width) / 2).rounded(), y: ((bounds.height - star.size.height) / 2).rounded()),
                                 size: star.size))
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
                let filled = n <= rating
                guard let image = symbol(filled ? "star.fill" : "star", size: Self.size, color: filled ? tint : .tertiaryLabelColor) else { continue }
                let origin = NSPoint(x: 2 + CGFloat(n - 1) * Self.step, y: ((bounds.height - image.size.height) / 2).rounded())
                image.draw(in: NSRect(origin: origin, size: image.size))
            }
        }
    }
}

/// Symbol images are made once per look; making them on each draw slows scrolling.
@MainActor private var symbols: [String: NSImage] = [:]

@MainActor private func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImage? {
    let key = "\(name) \(size) \(weight.rawValue) \(color)"
    if let image = symbols[key] { return image }
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    symbols[key] = image
    return image
}
