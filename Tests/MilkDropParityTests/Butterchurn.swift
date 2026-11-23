import CoreGraphics
import Foundation
import ImageIO
import WebKit

/// butterchurn (the JS/WebGL MilkDrop the app used before) in an offscreen web view, as the reference picture.
@MainActor final class Butterchurn: NSObject, WKNavigationDelegate {
    private let view: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?

    override init() {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        super.init()
        view.navigationDelegate = self
    }

    func load() async throws {
        guard let folder = Bundle.module.url(forResource: "Reference", withExtension: nil) else { throw ParityError("no Reference folder") }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            view.loadFileURL(folder.appendingPathComponent("reference.html"), allowingReadAccessTo: folder)
        }
    }

    /// Gives butterchurn the images of `folder` (it ships none), so presets that name textures compare fairly.
    func setImages(_ folder: URL) async throws {
        var urls: [String: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let type = file.pathExtension.lowercased() == "png" ? "png" : "jpeg"
            urls[file.deletingPathExtension().lastPathComponent] = "data:image/\(type);base64," + (try Data(contentsOf: file)).base64EncodedString()
        }
        _ = try await view.callAsyncJavaScript("return await setImages(urls)", arguments: ["urls": urls], contentWorld: .page)
    }

    /// `benchPreset` of reference.html: timings in ms, and why butterchurn cannot render the preset (empty if it can).
    func bench(_ milk: String, width: Int, height: Int, frames: Int) async throws -> (times: [String: Double], failure: String) {
        let result = try await view.callAsyncJavaScript(
            "return await benchPreset(milk, width, height, frames)",
            arguments: ["milk": milk, "width": width, "height": height, "frames": frames], contentWorld: .page)
        guard let r = result as? [String: Any] else { throw ParityError("no timings from butterchurn") }
        return (r.compactMapValues { ($0 as? NSNumber)?.doubleValue }, r["failure"] as? String ?? "")
    }

    /// Why butterchurn got the last `render` wrong (a shader it cannot link or the converter broke), nil when it did not.
    private(set) var failure: String?

    /// RGBA bytes, rows top first, of the frames in `keep` (1-based).
    func render(_ milk: String, width: Int, height: Int, frames: Int, keep: [Int]) async throws -> [Int: [UInt8]] {
        let result = try await view.callAsyncJavaScript(
            "return await renderPreset(milk, width, height, frames, keep)",
            arguments: ["milk": milk, "width": width, "height": height, "frames": frames, "keep": keep], contentWorld: .page)
        guard let urls = result as? [String: String] else { throw ParityError("no frames from butterchurn") }
        failure = urls["failure"]
        var out: [Int: [UInt8]] = [:]
        for (key, url) in urls {
            guard let frame = Int(key), let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
                  let pixels = Self.rgba(data, width: width, height: height) else { continue }
            out[frame] = pixels
        }
        return out
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }

    /// Decodes a PNG into RGBA bytes of the given size.
    static func rgba(_ png: Data, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }
}

struct ParityError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
