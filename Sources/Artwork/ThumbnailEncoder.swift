import CoreGraphics
import Foundation
import ImageIO

public enum ThumbnailEncoder {
    /// Aspect-fit size inside the format box, as libgpod computes it (no crop).
    static func fittedSize(width: Int, height: Int, in format: ArtworkFormat) -> (width: Int, height: Int) {
        let w, h: Int
        if format.width * height < format.height * width {  // width is the limiting side
            w = format.width
            h = min((height * format.width + width - 1) / max(width, 1), format.height)
        } else if format.width * height > format.height * width {
            w = min((width * format.height + height - 1) / max(height, 1), format.width)
            h = format.height
        } else {
            (w, h) = (format.width, format.height)
        }
        return (max(w, 1), max(h, 1))
    }

    /// Scales `image` to fit the format box, centers it on black and packs RGB565 LE.
    /// `width`/`height` are the values for the mhni header (fitted size including top-left padding).
    public static func rgb565(_ image: CGImage, format: ArtworkFormat)
        -> (data: Data, hPad: Int16, vPad: Int16, width: Int16, height: Int16)
    {
        let (w, h) = fittedSize(width: image.width, height: image.height, in: format)
        let hPad = (format.width - w) / 2
        let vPad = (format.height - h) / 2
        let pixels = rgba(image, width: w, height: h)

        var out = [UInt8](repeating: 0, count: format.byteSize)
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                let r = UInt16(pixels[p] >> 3), g = UInt16(pixels[p + 1] >> 2), b = UInt16(pixels[p + 2] >> 3)
                let v = r << 11 | g << 5 | b
                let o = ((y + vPad) * format.width + x + hPad) * 2
                out[o] = UInt8(v & 0xFF)
                out[o + 1] = UInt8(v >> 8)
            }
        }
        return (Data(out), Int16(hPad), Int16(vPad), Int16(hPad + w), Int16(vPad + h))
    }

    /// Decodes JPEG/PNG/... bytes.
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draws the image scaled into an opaque sRGB RGBA buffer (transparency composited on white).
    private static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return }
            ctx.interpolationQuality = .high
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }
}
