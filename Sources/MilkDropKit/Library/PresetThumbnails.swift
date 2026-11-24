import CoreGraphics
import Foundation
import ImageIO
import Metal

/// A short synthetic song for preset pictures: kick, bass, hi-hat and a little tune at 120 bpm, the same every time.
enum DemoTrack {
    static let rate = 44100.0

    /// The 1024 samples of frame `frame` at 60 fps.
    static func samples(frame: Int) -> [Float] {
        (0..<AudioLevels.sampleCount).map { i in
            let n = frame * 735 + i, t = Double(n) / rate
            let beat = t.truncatingRemainder(dividingBy: 0.5), half = (t + 0.25).truncatingRemainder(dividingBy: 0.5)
            let kick = sin(2 * .pi * (45 * beat + 25 * (1 - exp(-beat * 30)))) * exp(-beat * 9)
            let bass = 0.3 * sin(2 * .pi * [55.0, 55, 65.4, 49][Int(t / 2) % 4] * t) * min(beat * 40, 1)
            let noise = Double((n &* 1_103_515_245 &+ 12345) >> 8 & 0xFFFF) / 32768 - 1
            let hat = 0.25 * noise * exp(-half * 70)
            let tune = 0.15 * sin(2 * .pi * [440.0, 523.3, 659.3, 587.3][Int(t * 4) % 4] * t)
            return Float(max(min(0.6 * kick + bass + hat + tune, 1), -1))
        }
    }
}

/// Pictures of presets on the demo track, kept on disk by preset file (name, size and date), so a preset that
/// changes gets a new one. Made when a preset compiles ahead, or when the preset browser first shows it.
public final class PresetThumbnails: Sendable {
    /// The picture's size; it is rendered at `renderSize`, as the visualizer would, then scaled down.
    public static let size = SIMD2(384, 216)
    static let renderSize = SIMD2(960, 540)
    static let frames = 120
    private let folder: URL

    public init(folder: URL) { self.folder = folder }

    func url(_ entry: PresetLibrary.Entry) -> URL {
        let safe = entry.name.map { "/:\\".contains($0) ? "_" : $0 }
        return folder.appendingPathComponent(String(safe) + "-" + CompileIndex.stamp(entry.url) + "-v2.jpg")
    }

    /// The picture on disk, if made.
    public func cached(_ entry: PresetLibrary.Entry) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(entry) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Renders `compiled` for two seconds of the demo track and saves the last frame. Blocks the calling thread.
    @discardableResult
    func make(_ compiled: CompiledPreset, entry: PresetLibrary.Entry, device: MTLDevice, noise: Noise.Textures?) throws -> CGImage {
        guard let renderer = Renderer(device: device, noise: noise) else { throw CocoaError(.featureUnsupported) }
        let (w, h) = (Self.renderSize.x, Self.renderSize.y)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MilkDropController.screenFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let screen = device.makeTexture(descriptor: d) else { throw CocoaError(.featureUnsupported) }
        try renderer.show(compiled, blend: 0)
        var last: MTLCommandBuffer?
        for f in 0..<Self.frames {
            guard let buffer = renderer.queue.makeCommandBuffer() else { break }
            let a = DemoTrack.samples(frame: f)
            renderer.render(into: screen, buffer: buffer, size: Self.renderSize, left: a, right: a, sampleRate: DemoTrack.rate, now: Double(f) / 60)
            buffer.commit()
            last = buffer
        }
        last?.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        screen.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let full = Self.image(bgra: bytes, width: w, height: h), let image = Self.scaled(full, to: Self.size) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url(entry) as CFURL, "public.jpeg" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return image
    }

    private static func scaled(_ image: CGImage, to size: SIMD2<Int>) -> CGImage? {
        let context = CGContext(data: nil, width: size.x, height: size.y, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: size.x, height: size.y))
        return context?.makeImage()
    }

    private static func image(bgra: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
