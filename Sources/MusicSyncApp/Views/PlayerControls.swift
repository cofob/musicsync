import AVKit
import SwiftUI

/// Shuffle, previous, play/pause, next, repeat. `scale` 1 fits the bottom capsule.
struct TransportControls: View {
    @Environment(AppModel.self) private var model
    var scale: CGFloat = 1
    var spacing: CGFloat = 14

    var body: some View {
        let player = model.player
        HStack(spacing: spacing) {
            toggle("Shuffle", "shuffle", isOn: player.shuffle) { player.setShuffle(!player.shuffle) }
            Button("Previous", systemImage: "backward.fill") { player.previous() }
                .font(.system(size: 17 * scale)).disabled(!player.hasPrevious)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                .font(.system(size: 24 * scale)).frame(width: 28 * scale).disabled(player.queue.isEmpty)
            Button("Next", systemImage: "forward.fill") { player.next() }
                .font(.system(size: 17 * scale)).disabled(!player.hasNext)
            toggle("Repeat", player.repeatMode.symbol, isOn: player.repeatMode != .off) { player.repeatMode = player.repeatMode.next }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(HitAreaButtonStyle())
    }

    private func toggle(_ title: String, _ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: symbol, action: action)
            .font(.system(size: 13 * scale, weight: .semibold))
            .foregroundStyle(isOn ? AnyShapeStyle(Color.musicAccent) : AnyShapeStyle(.secondary))
            .help(title)
    }
}

/// Thin capsule level bar; drag or click to change. Thickens on hover.
struct LevelBar: View {
    let value: Double
    var height: CGFloat = 4
    var tint: Color = .primary
    var onChange: (Double) -> Void = { _ in }
    var onCommit: (Double) -> Void
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
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { onChange(fraction($0.location.x, geo.size.width)) }
                    .onEnded { onCommit(fraction($0.location.x, geo.size.width)) })
        }
        .frame(height: max(14, height * 2))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double { Double(min(max(x / max(width, 1), 0), 1)) }
}

/// Song progress with elapsed and remaining time; seeks on release.
struct ScrubBar: View {
    @Environment(AppModel.self) private var model
    var height: CGFloat = 4
    var tint: Color = .primary
    /// Times beside the bar (capsule) or under it (Now Playing).
    var timesBelow = false
    @State private var scrub: Double?

    var body: some View {
        let player = model.player
        let duration = player.duration
        let elapsed = scrub ?? player.elapsed
        let bar = LevelBar(value: duration > 0 ? elapsed / duration : 0, height: height, tint: tint,
                           onChange: { scrub = $0 * duration },
                           onCommit: { player.seek(to: $0 * duration); scrub = nil })
        let start = Text(formatTime(elapsed))
        let end = Text("−" + formatTime(max(0, duration - elapsed)))
        Group {
            if timesBelow {
                VStack(spacing: 2) {
                    bar
                    HStack { start; Spacer(); end }
                }
            } else {
                HStack(spacing: 8) { start.frame(minWidth: 34, alignment: .leading); bar; end.frame(minWidth: 38, alignment: .trailing) }
            }
        }
        .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(tint.opacity(0.6))
    }
}

/// AirPlay route picker for the app's player.
struct AirPlayButton: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    var tint: NSColor = .labelColor

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.player = model.player.routingPlayer
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
                 onChange: { player.volume = $0 }, onCommit: { player.volume = $0 })
    }
}

/// Speaker button that expands into a volume slider.
struct VolumeButton: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var collapse: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            if expanded { VolumeSlider().frame(width: 110).transition(.opacity.combined(with: .move(edge: .trailing))) }
            Button("Volume", systemImage: volumeSymbol(model.player.volume)) {
                withAnimation(.snappy) { expanded.toggle() }
            }
            .labelStyle(.iconOnly).buttonStyle(HitAreaButtonStyle(width: 24, height: 24)).font(.system(size: 17))
        }
        .padding(.horizontal, expanded ? 12 : 0).padding(.vertical, expanded ? 6 : 0)
        .background { if expanded { Capsule().fill(.primary.opacity(0.08)) } }
        .onHover { inside in
            collapse?.cancel()
            guard !inside, expanded else { return }
            collapse = Task {
                guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
                withAnimation(.snappy) { expanded = false }
            }
        }
    }
}
