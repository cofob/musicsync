import AVFoundation
import CoreVideo
import Foundation

/// Pictures of the visualizer suite: difference images and side-by-side H.264 videos.
enum SuiteVideo {
    static let w = ParityTests.size.w, h = ParityTests.size.h

    /// |a − b| per channel, 4× brighter, as a PNG.
    nonisolated static func saveDifference(_ a: [UInt8], _ b: [UInt8], to url: URL) {
        var d = [UInt8](repeating: 255, count: a.count)
        for i in 0..<a.count where i % 4 != 3 { d[i] = UInt8(min(abs(Int(a[i]) - Int(b[i])) * 4, 255)) }
        ParityTests.savePNG(d, to: url)
    }

    /// Writes `frames` frames at 60 per second; `panels(f)` gives the RGBA pictures of frame f (1-based), left to right,
    /// nil for a black panel.
    @MainActor static func write(to url: URL, frames: Int, panels: (Int) -> [[UInt8]?]) async throws {
        try? FileManager.default.removeItem(at: url)
        let count = panels(1).count
        let width = w * count
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ParityError("cannot write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)
        for f in 1...frames {
            // Few small frames: the encoder is nearly always ready.
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw ParityError("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ParityError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for (k, panel) in panels(f).enumerated() {
                for y in 0..<h {
                    let row = base + y * stride + k * w * 4
                    for x in 0..<w {
                        let i = (y * w + x) * 4
                        if let p = panel { (row[x * 4], row[x * 4 + 1], row[x * 4 + 2]) = (p[i + 2], p[i + 1], p[i]) }
                        else { (row[x * 4], row[x * 4 + 1], row[x * 4 + 2]) = (0, 0, 0) }
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f - 1), timescale: 60)) else {
                throw writer.error ?? ParityError("cannot add frame \(f)")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ParityError("video not finished") }
    }
}
