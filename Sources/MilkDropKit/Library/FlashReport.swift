import Foundation

/// How much a preset flashes, measured as the photosensitivity rules do (WCAG 2.3.1, ITU-R BT.1702): a general
/// flash is a pair of opposing changes of relative luminance of at least 0.1 where the darker state is below 0.8;
/// a red flash is the same for saturated red (red share of at least 0.8, change of (R − G − B) of at least 20 / 320).
/// A rate counts only what flashes over at least a quarter of the screen: the 48 × 27 cells of a frame are judged
/// one by one, and the rate is the one that a quarter of the cells reach. The worst second of the clip counts.
public struct FlashReport: Codable, Equatable, Sendable {
    /// Most general flashes in any second.
    public var general: Double
    /// Most red flashes in any second.
    public var red: Double
    /// Most flashes in any second of the whole picture's brightness, at a swing of 0.25 or more: a stricter check
    /// for big jumps of the full screen.
    public var screen: Double

    /// A preset needs fewer flashes in a second than these. The rules allow three; fewer is the conservative side.
    public static let limits = (general: 3.0, red: 3.0, screen: 2.0)
    static let delta = (general: 0.1, red: 20.0 / 320, screen: 0.25)
    /// Share of the screen that must flash.
    static let area = 0.25
    static let darker = 0.8
    /// Least share of red in a saturated red.
    static let redShare = 0.8

    public init(general: Double, red: Double, screen: Double) {
        (self.general, self.red, self.screen) = (general, red, screen)
    }

    public var isSafe: Bool { general < Self.limits.general && red < Self.limits.red && screen < Self.limits.screen }

    /// Measures `frames` shown `fps` times a second; the same size for all.
    init(_ frames: [LookFrame], fps: Int = 60) {
        guard let first = frames.first, frames.allSatisfy({ $0.rgb.count == first.rgb.count }) else { self.init(general: 0, red: 0, screen: 0); return }
        let cells = first.width * first.height
        var luminance = [[Double]](repeating: [], count: cells), red = luminance
        for frame in frames {
            let pixels = frame.pixels.map { SIMD3(Self.linear($0.x), Self.linear($0.y), Self.linear($0.z)) }
            for (c, p) in pixels.enumerated() {
                luminance[c].append(0.2126 * p.x + 0.7152 * p.y + 0.0722 * p.z)
                red[c].append(p.x / max(p.x + p.y + p.z, 1e-9) >= Self.redShare ? max(p.x - p.y - p.z, 0) : 0)
            }
        }
        let screen = (0..<frames.count).map { f in luminance.reduce(0) { $0 + $1[f] } / Double(cells) }
        self.init(general: Self.rate(luminance, fps: fps, delta: Self.delta.general, below: Self.darker),
                  red: Self.rate(red, fps: fps, delta: Self.delta.red),
                  screen: Self.rate([screen], fps: fps, delta: Self.delta.screen, area: 1))
    }

    /// Display brightness of a color value (sRGB transfer function).
    static func linear(_ v: Float) -> Double {
        let c = Double(v)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// The frames at which `series` swings by `delta` or more, at the frame where the swing is done. A swing counts
    /// only when its lower end is below `below`. A slow fade is one swing, however long it takes.
    static func swings(_ series: [Double], delta: Double, below: Double = .infinity) -> [Int] {
        guard var low = series.first else { return [] }
        var high = low, direction = 0, found: [Int] = []
        for (i, v) in series.enumerated() {
            if direction <= 0, v < low { low = v }
            if direction >= 0, v > high { high = v }
            if direction <= 0, v - low >= delta {  // up
                if low < below { found.append(i) }
                (direction, high) = (1, v)
            } else if direction >= 0, high - v >= delta {  // down
                if v < below { found.append(i) }
                (direction, low) = (-1, v)
            }
        }
        return found
    }

    /// The flashes (pairs of swings) per second that `area` of the series reach in their worst second.
    static func rate(_ series: [[Double]], fps: Int, delta: Double, below: Double = .infinity, area: Double = FlashReport.area) -> Double {
        guard let length = series.first?.count, length > 0 else { return 0 }
        // Swings up to each frame, per series.
        let totals = series.map { s in
            var counts = [Int](repeating: 0, count: length + 1)
            for i in swings(s, delta: delta, below: below) { counts[i + 1] += 1 }
            for i in 1...length { counts[i] += counts[i - 1] }
            return counts
        }
        let rank = max(Int((Double(series.count) * area).rounded(.up)), 1) - 1
        return (0..<length).map { f in
            let swings = totals.map { $0[f + 1] - $0[max(f + 1 - fps, 0)] }.sorted(by: >)
            return Double(swings[rank]) / 2
        }.max() ?? 0
    }
}
