import AVFoundation
@testable import Playback
import Testing

/// Serves `StubServer.data` for any URL, with byte ranges unless `ranges` is off.
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var data = Data()
    nonisolated(unsafe) static var ranges = true

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let data = Self.data, url = request.url!
        var body = data, status = 200, headers = ["Content-Type": "audio/wav", "Content-Length": "\(data.count)"]
        if Self.ranges, let range = request.value(forHTTPHeaderField: "Range")?.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false),
           let start = Int(range[0]) {
            let end = min(range.count > 1 ? Int(range[1]) ?? data.count - 1 : data.count - 1, data.count - 1)
            body = data.subdata(in: start..<end + 1)
            status = 206
            headers["Content-Length"] = "\(body.count)"
            headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor @Suite(.slow, .serialized) struct StreamLoaderTests {
    /// A stream that AVFoundation fetches itself runs no audio tap; through the loader it does.
    @Test(arguments: [true, false]) func tapRunsOnStream(ranges: Bool) async throws {
        StubServer.data = try Data(contentsOf: try await ClickTrack(bpm: 120, body: 6).file())
        StubServer.ranges = ranges
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        let mixer = Mixer()
        mixer.volume = 0
        mixer.equalizer.samples.isOn = true
        mixer.usesEqualizer = true
        mixer.play(Mixer.Cue(item: AVPlayerItem(asset: StreamLoader.asset(URL(string: "http://server/stream?id=1")!, configuration: config))))
        try await Task.sleep(for: .seconds(2))
        #expect(mixer.time > 1)
        #expect(mixer.equalizer.processedFrames > 44100)
        #expect(mixer.equalizer.samples.latest(4096, at: mixer.time).left.contains { abs($0) > 0.05 })
        mixer.stop()
    }
}

@Suite struct StreamLoaderUnitTests {
    @Test func totalLengthFromContentRange() {
        let url = URL(string: "http://server")!
        let ranged = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 0-1/12345"])!
        #expect(StreamLoader.totalLength(ranged) == 12345)
        #expect(StreamLoader.totalLength(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!) == nil)
    }
}
