import Playback
import SwiftUI

/// Winamp's classic spectrum analyzer: segmented bars from green to red with falling peak caps.
struct SpectrumVisualizer: View {
    let player: Player
    @AppStorage(VisualizerSettings.peaks, store: .app) private var peaks = true
    @AppStorage(VisualizerSettings.segmented, store: .app) private var segmented = true
    @AppStorage(VisualizerSettings.falloff, store: .app) private var falloff = 1.6
    @State private var state = State()

    final class State {
        let spectrum = Spectrum()
        var falloff = Falloff()
        var last: Date?
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let small = size.width < 400
                let barWidth: CGFloat = small ? 6 : 12, gap: CGFloat = small ? 2 : 3, pad: CGFloat = small ? 8 : 20
                let count = max(Int((size.width - 2 * pad + gap) / (barWidth + gap)), 1)
                let samples = player.mixer.equalizer.samples.latest(Spectrum.size, at: player.mixer.time)
                let mono = zip(samples.left, samples.right).map { ($0 + $1) / 2 }
                let dt = state.last.map { timeline.date.timeIntervalSince($0) } ?? 0
                state.last = timeline.date
                state.falloff.barFall = Float(falloff)
                state.falloff.update(state.spectrum.bands(mono, sampleRate: player.mixer.equalizer.samples.sampleRate, count: count), dt: dt)
                let height = max(size.height - 2 * pad, 1), bottom = size.height - pad
                let x0 = (size.width - CGFloat(count) * (barWidth + gap) + gap) / 2
                // One gradient over the full height, so a bar turns from green to red as it grows.
                let gradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Self.color(1), Self.color(0.5), Self.color(0)]), startPoint: CGPoint(x: 0, y: pad), endPoint: CGPoint(x: 0, y: bottom))
                var dim = Path(), lit = Path(), caps = Path()
                for i in 0..<count {
                    let x = x0 + CGFloat(i) * (barWidth + gap)
                    let bar = CGFloat(state.falloff.bars[i]) * height
                    dim.addRect(CGRect(x: x, y: pad, width: barWidth, height: height))
                    lit.addRect(CGRect(x: x, y: bottom - bar, width: barWidth, height: bar))
                    if peaks { caps.addRect(CGRect(x: x, y: bottom - CGFloat(state.falloff.peaks[i]) * height - 2, width: barWidth, height: 2)) }
                }
                context.fill(dim, with: .color(.white.opacity(0.05)))
                context.fill(lit, with: gradient)
                if segmented {
                    // Black gaps cut the bars into LED segments, as in Winamp.
                    let gaps = Path { p in for y in stride(from: bottom - 4, to: pad, by: -4) { p.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) } }
                    context.fill(gaps, with: .color(.black))
                }
                context.fill(caps, with: .color(.white.opacity(0.85)))
            }
        }
    }

    /// Green at the bottom, yellow in the middle, red at the top.
    static func color(_ level: Double) -> Color {
        Color(hue: 0.33 * (1 - level), saturation: 0.9, brightness: 0.95)
    }
}

/// AIMP-style oscilloscope: the left and right channels as glowing lines that leave a short trail.
struct ScopeVisualizer: View {
    let player: Player
    @State private var state = State()

    final class State { var trail: [(left: [Float], right: [Float])] = [] }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                _ = timeline.date  // redraws on every frame: the samples are not a SwiftUI input
                let frame = player.mixer.equalizer.samples.latest(1024, at: player.mixer.time)
                state.trail = Array((state.trail + [frame]).suffix(3))
                for (age, frame) in state.trail.reversed().enumerated() {
                    let opacity = 1 - Double(age) / 3
                    for (samples, color, row) in [(frame.left, Color(red: 0.3, green: 1, blue: 0.5), 0.3), (frame.right, Color(red: 0.3, green: 0.8, blue: 1), 0.7)] {
                        let path = Self.line(samples, in: size, middle: size.height * row, amplitude: size.height * 0.25)
                        if age == 0 { context.stroke(path, with: .color(color.opacity(0.2)), lineWidth: 5) }  // glow
                        context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: age == 0 ? 2 : 1.5)
                    }
                }
            }
        }
    }

    private static func line(_ samples: [Float], in size: CGSize, middle: CGFloat, amplitude: CGFloat) -> Path {
        Path { path in
            // About one point per 2 px: more only costs stroke time.
            let count = min(samples.count, max(Int(size.width / 2), 2))
            guard count > 1 else { return }
            let step = size.width / CGFloat(count - 1), stride = Double(samples.count) / Double(count)
            for i in 0..<count {
                let sample = samples[min(Int(Double(i) * stride), samples.count - 1)]
                let point = CGPoint(x: CGFloat(i) * step, y: middle - CGFloat(max(min(sample, 1), -1)) * amplitude)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
