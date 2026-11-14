import AppKit
import Observation
import Preferences
import SwiftUI

/// The "Album Color" accent: a strong color of the current cover. The player sets `image`;
/// the color is worked out once per cover, on the first read.
@MainActor @Observable
final class CoverAccent {
    static let shared = CoverAccent()

    var image: NSImage? { didSet { if image !== oldValue { cached = nil } } }
    @ObservationIgnored private var cached: Color??

    /// Nil without a cover or for a gray one.
    var color: Color? {
        if let cached { return cached }
        let color = image.flatMap(coverSamples).flatMap(AppearanceSettings.Accent.vivid).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        cached = .some(color)
        return color
    }
}

/// The image averaged into a 3×3 grid of sRGB colors, row by row.
@MainActor func coverSamples(_ image: NSImage) -> [AppearanceSettings.Accent.RGB]? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let data = ctx.data else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 3, height: 3))
    let px = data.bindMemory(to: UInt8.self, capacity: 36)
    return (0..<9).map { i in (Double(px[4 * i]) / 255, Double(px[4 * i + 1]) / 255, Double(px[4 * i + 2]) / 255) }
}
