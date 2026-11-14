import Foundation
import Subsonic
import Testing

/// A server that converts to mp3 only: other formats come back as the original FLAC; `fail` gives HTTP 500.
final class ConvertingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fail = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "format" }?.value
        let type = format == "mp3" ? "audio/mpeg" : "audio/flac"
        let response = HTTPURLResponse(url: url, statusCode: Self.fail ? 500 : 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(count: 4096))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct TranscodeProbeTests {
    @Test func matchesContentTypes() {
        #expect(TranscodeProbe.matches(format: "mp3", contentType: "audio/mpeg"))
        #expect(TranscodeProbe.matches(format: "aac", contentType: "audio/mp4; charset=binary"))
        #expect(TranscodeProbe.matches(format: "aac", contentType: "AUDIO/AAC"))
        #expect(!TranscodeProbe.matches(format: "aac", contentType: "audio/flac"))
        #expect(!TranscodeProbe.matches(format: "mp3", contentType: nil))
        #expect(!TranscodeProbe.matches(format: "opus", contentType: "audio/ogg"))
    }

    @Test func findsConvertibleFormats() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConvertingStub.self]
        let c = SubsonicClient(baseURL: URL(string: "https://music.example.com")!, username: "u", password: "p",
                               session: URLSession(configuration: config))
        ConvertingStub.fail = false
        #expect(await c.convertibleFormats(songID: "s-1") == ["mp3"])
        ConvertingStub.fail = true
        #expect(await c.convertibleFormats(songID: "s-1") == nil)
        ConvertingStub.fail = false
    }
}
