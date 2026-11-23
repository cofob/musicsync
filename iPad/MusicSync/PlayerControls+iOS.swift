import AVKit
import SwiftUI

/// Taps and drags on a `LevelBar`, as fractions of its width. The hit area is taller than the bar, for a finger.
struct BarMouseArea: View {
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let fraction = { (x: CGFloat) in Double(min(max(x / max(geo.size.width, 1), 0), 1)) }
            Color.clear.contentShape(Rectangle().inset(by: -10))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { onChange(fraction($0.location.x)) }
                    .onEnded { onCommit(fraction($0.location.x)) })
        }
    }
}

/// On the Mac it keeps the window still under the controls; iPad windows do not move on a drag.
struct WindowStill: View {
    var body: some View { Color.clear }
}

/// AirPlay route picker for the system output (see the Mac version).
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = UIColor(Color.musicAccent)
    }
}
