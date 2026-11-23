import AVKit
import SwiftUI

/// Shuffle, previous, play/pause, next, repeat; `compact` leaves out shuffle and repeat. `scale` 1 fits the bottom capsule.
struct TransportControls: View {
    @Environment(AppModel.self) private var model
    var scale: CGFloat = 1
    var spacing: CGFloat = 14
    var compact = false

    var body: some View {
        let player = model.player
        HStack(spacing: spacing) {
            if !compact { toggle("Shuffle", "shuffle", isOn: player.shuffle, value: player.shuffle ? "On" : "Off") { player.setShuffle(!player.shuffle) } }
            Button("Previous", systemImage: "backward.fill") { player.previous() }
                .font(.system(size: 17 * scale)).disabled(!player.hasPrevious)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                .font(.system(size: 24 * scale)).frame(width: 28 * scale).disabled(player.queue.isEmpty)
            Button("Next", systemImage: "forward.fill") { player.next() }
                .font(.system(size: 17 * scale)).disabled(!player.hasNext)
            if !compact { toggle("Repeat", player.repeatMode.symbol, isOn: player.repeatMode != .off, value: player.repeatMode.rawValue.capitalized) { player.repeatMode = player.repeatMode.next } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(HitAreaButtonStyle())
    }

    private func toggle(_ title: String, _ symbol: String, isOn: Bool, value: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .font(.system(size: 13 * scale, weight: .semibold))
            .foregroundStyle(isOn ? AnyShapeStyle(Color.musicAccent) : AnyShapeStyle(.secondary))
            .help(title)
            .accessibilityValue(value)
    }
}

/// Thin capsule level bar; drag or click to change. Thickens on hover.
struct LevelBar: View {
    let value: Double
    var height: CGFloat = 4
    var tint: Color = .primary
    var onChange: (Double) -> Void = { _ in }
    var onCommit: (Double) -> Void
    /// What VoiceOver reads: the name, the value, and the change of one increment or decrement.
    var label = ""
    var valueText = ""
    var step = 0.05
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let h = hovering ? height * 1.6 : height
            Capsule().fill(tint.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.85)).frame(width: max(h, geo.size.width * min(max(value, 0), 1)))
                }
                .frame(height: h)
                .frame(maxHeight: .infinity)
                .overlay(BarMouseArea(onChange: onChange, onCommit: onCommit))
        }
        .frame(height: max(14, height * 2))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { onCommit($0) }), in: 0...1, step: step) { Text(label) }
                .accessibilityValue(valueText)
        }
    }
}

/// Clicks and drags on a `LevelBar`, as fractions of its width. An AppKit view, because a SwiftUI drag
/// in the title bar area (Now Playing) or in a window movable by its background (MiniPlayer) moves the window.
struct BarMouseArea: NSViewRepresentable {
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    func makeNSView(context: Context) -> AreaView { AreaView() }

    func updateNSView(_ view: AreaView, context: Context) {
        view.onChange = onChange
        view.onCommit = onCommit
    }

    final class AreaView: NSView {
        var onChange: (Double) -> Void = { _ in }
        var onCommit: (Double) -> Void = { _ in }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onChange(fraction(event)) }
        override func mouseDragged(with event: NSEvent) { onChange(fraction(event)) }
        override func mouseUp(with event: NSEvent) { onCommit(fraction(event)) }

        private func fraction(_ event: NSEvent) -> Double {
            Double(min(max(convert(event.locationInWindow, from: nil).x / max(bounds.width, 1), 0), 1))
        }
    }
}

/// The window does not move while the mouse is here. In the title bar area (Now Playing) the window server moves it
/// on a drag, and it does not see the SwiftUI controls there: clicks and drags on them would move the window.
struct WindowStill: NSViewRepresentable {
    func makeNSView(context: Context) -> StillView { StillView() }
    func updateNSView(_ view: StillView, context: Context) {}

    final class StillView: NSView {
        private var held: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hold(window) }
        override func mouseExited(with event: NSEvent) { hold(nil) }
        override func viewWillMove(toWindow newWindow: NSWindow?) { hold(nil) }

        private func hold(_ window: NSWindow?) {
            held?.isMovable = true
            held = window
            window?.isMovable = false
        }
    }
}

/// Song progress with elapsed and remaining time; seeks on release. The VoiceOver step is 10 s, the whole bar for short
/// or unknown lengths: a zero step traps in `Slider`.
struct ScrubBar: View {
    @Environment(AppModel.self) private var model
    var height: CGFloat = 4
    var tint: Color = .primary
    /// Times beside the bar (capsule) or under it (Now Playing).
    var timesBelow = false
    /// False hides the times beside the bar.
    var showsTimes = true
    @State private var scrub: Double?

    var body: some View {
        let player = model.player
        let duration = player.duration
        let elapsed = scrub ?? player.elapsed
        let bar = LevelBar(value: duration > 0 ? elapsed / duration : 0, height: height, tint: tint,
                           onChange: { scrub = $0 * duration },
                           onCommit: { player.seek(to: $0 * duration); scrub = nil },
                           label: "Position", valueText: "\(spokenTime(elapsed)) of \(spokenTime(duration))", step: duration > 10 ? 10 / duration : 1)
        let start = Text(formatTime(elapsed))
        let end = Text("−" + formatTime(max(0, duration - elapsed)))
        Group {
            if player.current?.isLive == true {
                LiveLabel()
            } else if timesBelow {
                VStack(spacing: 2) {
                    bar
                    HStack { start; Spacer(); end }
                }
            } else if !showsTimes {
                bar
            } else {
                HStack(spacing: 8) { start.frame(minWidth: 34, alignment: .leading); bar; end.frame(minWidth: 38, alignment: .trailing) }
            }
        }
        .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(tint.opacity(0.6))
    }
}

/// AirPlay route picker. It has no player and so routes the system output: the player plays on two decks
/// during a crossfade, and a picker bound to one `AVPlayer` would move only that one.
struct AirPlayButton: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    var tint: NSColor = .labelColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.setRoutePickerButtonColor(tint, for: .normal)
        view.setRoutePickerButtonColor(NSColor(Color.musicAccent), for: .active)
    }
}

/// Speaker symbol for a volume level.
func volumeSymbol(_ volume: Double) -> String {
    volume == 0 ? "speaker.slash.fill" : volume < 0.33 ? "speaker.wave.1.fill" : volume < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
}

/// Volume slider bound to the player.
struct VolumeSlider: View {
    @Environment(AppModel.self) private var model
    var tint: Color = .primary

    var body: some View {
        let player = model.player
        LevelBar(value: player.volume, height: 5, tint: tint,
                 onChange: { player.volume = $0 }, onCommit: { player.volume = $0 },
                 label: "Volume", valueText: "\(Int((player.volume * 100).rounded()))%", step: 0.1)
    }
}

/// The icons in `content`, then a speaker button. Hovering or clicking the speaker turns them all into a
/// volume slider in a capsule; it goes back when the pointer leaves.
struct VolumeButton<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content
    @State private var expanded = Shot.scene == "volume"

    var body: some View {
        let symbol = volumeSymbol(model.player.volume)
        HStack(spacing: 18) {
            content
            Button("Volume", systemImage: symbol) { expand(!expanded) }
                .onHover { if $0 { expand(true) } }
        }
        .opacity(expanded ? 0 : 1)
        .overlay(alignment: .trailing) {
            if expanded {
                HStack(spacing: 8) {
                    VolumeSlider()
                    Image(systemName: symbol).frame(width: 24)
                }
                .padding(.leading, 14).padding(.trailing, 6)
                .frame(height: 40)
                .background(.background.opacity(0.8), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.1), radius: 6, y: 1)
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
            }
        }
        .onHover { if !$0 { expand(false) } }
    }

    private func expand(_ on: Bool) { withAnimation(.snappy(duration: 0.25)) { expanded = on } }
}
