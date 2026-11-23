import SwiftUI

extension Lyrics {
    /// Index of the synced line sung at `time`; nil before the first line and for unsynced lyrics.
    func line(at time: TimeInterval) -> Int? {
        isSynced ? lines.lastIndex { ($0.start ?? .infinity) <= time + 0.25 } : nil
    }
}

/// Synced lyrics over the spectrum and the oscilloscope, karaoke style: the current line large in the lower third,
/// its neighbours dim. (MilkDrop draws the lines into the preset itself, see `MilkDrop.title`.)
struct VisualizerLyrics: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lyrics: Lyrics
    let current: Int

    var body: some View {
        GeometryReader { geo in
            let size = min(max(geo.size.width / 24, 22), 56)
            VStack(spacing: size * 0.4) {
                line(current - 1, size: size * 0.55, opacity: 0.35)
                line(current, size: size, opacity: 1)
                line(current + 1, size: size * 0.55, opacity: 0.45)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.72)
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: current)
        }
        .allowsHitTesting(false)
    }

    /// One line, keyed by its index so a new line slides in while the old one fades.
    private func line(_ index: Int, size: CGFloat, opacity: Double) -> some View {
        let text = lyrics.lines.indices.contains(index) ? lyrics.lines[index].text : ""
        return Text(text.isEmpty ? " " : text)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
            .foregroundStyle(.white.opacity(opacity))
            .shadow(color: .black.opacity(0.8), radius: 6)
            .shadow(color: .white.opacity(opacity == 1 ? 0.35 : 0), radius: 16)  // glow on the sung line
            .id(index)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }
}
