import Foundation
import Support

/// A small color picture of a rendered frame: 3 values (red, green, blue, 0…1) per pixel.
struct LookFrame: Equatable {
    var width: Int
    var height: Int
    var rgb: [Float]

    /// Shrinks BGRA bytes (rows of `bytesPerRow`) to at most `width` × `height`, each pixel the mean of a block.
    init(bgra bytes: [UInt8], width w: Int, height h: Int, shrunkTo size: SIMD2<Int> = SIMD2(48, 27)) {
        width = min(size.x, w)
        height = min(size.y, h)
        rgb = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let (y0, y1) = (y * h / height, max((y + 1) * h / height, y * h / height + 1))
            for x in 0..<width {
                let (x0, x1) = (x * w / width, max((x + 1) * w / width, x * w / width + 1))
                var sum = SIMD3<Float>(repeating: 0)
                for j in y0..<y1 {
                    for i in x0..<x1 {
                        let p = (j * w + i) * 4
                        sum += SIMD3(Float(bytes[p + 2]), Float(bytes[p + 1]), Float(bytes[p]))
                    }
                }
                let mean = sum / Float((y1 - y0) * (x1 - x0)) / 255
                let o = (y * width + x) * 3
                (rgb[o], rgb[o + 1], rgb[o + 2]) = (mean.x, mean.y, mean.z)
            }
        }
    }

    /// A frame of one color, for tests.
    init(width: Int, height: Int, fill: (_ x: Int, _ y: Int) -> SIMD3<Float>) {
        (self.width, self.height) = (width, height)
        rgb = (0..<width * height).flatMap { i in
            let c = fill(i % width, i / width)
            return [c.x, c.y, c.z]
        }
    }

    var pixels: [SIMD3<Float>] { (0..<width * height).map { SIMD3(rgb[$0 * 3], rgb[$0 * 3 + 1], rgb[$0 * 3 + 2]) } }

    /// Mean absolute difference of all color values, 0…1.
    func difference(from other: LookFrame) -> Double {
        guard rgb.count == other.rgb.count, !rgb.isEmpty else { return 0 }
        return Double(zip(rgb, other.rgb).reduce(Float(0)) { $0 + abs($1.0 - $1.1) }) / Double(rgb.count)
    }
}

/// How a preset looks and moves on the demo track, measured from a few of its frames, and the mood those suggest.
public struct PresetLook: Codable, Equatable, Sendable {
    /// Mean brightness (Rec. 709 luma), 0…1.
    public var brightness: Double
    /// Mean color saturation (HSV), 0…1.
    public var saturation: Double
    /// −1 cold (blue) … 1 warm (red), the red-blue difference of the colored pixels.
    public var warmth: Double
    /// Standard deviation of the luma, 0…0.5.
    public var contrast: Double
    /// Mean change of the picture over 0.1 s away from the beat, 0…1.
    public var motion: Double
    /// How much stronger the picture changes across a kick than away from it, 0…1.
    public var beatReaction: Double

    public init(brightness: Double, saturation: Double, warmth: Double, contrast: Double, motion: Double, beatReaction: Double) {
        (self.brightness, self.saturation, self.warmth) = (brightness, saturation, warmth)
        (self.contrast, self.motion, self.beatReaction) = (contrast, motion, beatReaction)
    }

    /// Measures frames of the demo track: `shown` are pictures to judge the colors by; `kick` is a frame before and one
    /// after a kick; `quiet` two frames as far apart in time, between kicks.
    init(shown: [LookFrame], kick: (LookFrame, LookFrame), quiet: (LookFrame, LookFrame)) {
        var luma = [Double](), saturation = [Double](), warmth = 0.0, colored = 0.0
        for frame in shown {
            for c in frame.pixels {
                let top = Double(max(c.x, c.y, c.z)), bottom = Double(min(c.x, c.y, c.z))
                luma.append(0.2126 * Double(c.x) + 0.7152 * Double(c.y) + 0.0722 * Double(c.z))
                saturation.append(top > 0 ? (top - bottom) / top : 0)
                warmth += (top - bottom) * Double(c.x - c.z)
                colored += top - bottom
            }
        }
        let n = Double(max(luma.count, 1)), mean = luma.reduce(0, +) / n
        brightness = mean
        self.saturation = saturation.reduce(0, +) / n
        self.warmth = colored > 0 ? warmth / colored : 0
        contrast = (luma.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n).squareRoot()
        let (across, away) = (kick.0.difference(from: kick.1), quiet.0.difference(from: quiet.1))
        motion = away
        beatReaction = min(max((across - away) / (across + away + 0.002), 0), 1)
    }

    /// The mood the look suggests (all terms scaled to 0…1 by the ranges that bundled presets span):
    /// - arousal = 0.4 motion (0…0.05) + 0.3 beat reaction + 0.15 contrast + 0.15 saturation.
    /// - valence = 0.5 brightness (0.05…0.5) + 0.3 warmth (−0.3…0.3) + 0.2 saturation.
    /// - tension = 0.5 contrast (0.05…0.3) + 0.3 beat reaction + 0.2 coldness.
    public var mood: Mood {
        let contrast = Mood.scaled(contrast, 0.05, 0.3), warm = Mood.scaled(warmth, -0.3, 0.3)
        return Mood(arousal: 0.4 * Mood.scaled(motion, 0, 0.05) + 0.3 * beatReaction + 0.15 * contrast + 0.15 * saturation,
                    valence: 0.5 * Mood.scaled(brightness, 0.05, 0.5) + 0.3 * warm + 0.2 * saturation,
                    tension: 0.5 * contrast + 0.3 * beatReaction + 0.2 * (1 - warm))
    }
}
