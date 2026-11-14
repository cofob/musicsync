import Foundation
import Testing
@testable import Remote

/// A fixed-seed generator, so a failing input can be found again.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct HTTPFuzzTests {
    static let seeds = [
        "GET / HTTP/1.1\r\nHost: mac.local\r\n\r\n",
        "POST /api/command/seek?time=12 HTTP/1.1\r\nContent-Length: 13\r\nCookie: musicsync_token=abc\r\n\r\n{\"time\": 30} ",
        "POST /api/command/queue HTTP/1.1\r\nContent-Length: 31\r\n\r\n{\"offset\":99999999999999999999}",
        "GET /cover/al%2F1%ZZ?x=%&y HTTP/1.1\r\nAuthorization: Bearer \r\n\r\n",
        "POST /api/pair HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
    ]

    /// Checks the parser's promises for one input and routes what it parses.
    private func check(_ data: Data) {
        switch HTTPRequest.parse(data) {
        case .request(let r, let used):
            #expect(used > 0 && used <= data.count)
            _ = RemoteRoute.parse(r)
            _ = r.parameters
            _ = r.token
        case .incomplete: #expect(data.count <= HTTPRequest.maxHeaderBytes + HTTPRequest.maxBodyBytes + 4)
        case .invalid: break
        }
    }

    @Test func mutatedRequestsNeverTrap() {
        var random = SplitMix(state: 42)
        let alphabet = Array("\r\n :/?&=%{}\"0-9aZ\u{0}\u{ff}".utf8)
        for seed in Self.seeds {
            for _ in 0..<2000 {
                var bytes = Array(seed.utf8)
                for _ in 0..<Int.random(in: 1...4, using: &random) {
                    let i = Int.random(in: 0..<bytes.count, using: &random)
                    switch Int.random(in: 0..<4, using: &random) {
                    case 0: bytes[i] = alphabet.randomElement(using: &random) ?? 0
                    case 1: bytes.insert(UInt8.random(in: 0...255, using: &random), at: i)
                    case 2: if bytes.count > 1 { bytes.remove(at: i) }
                    default: bytes = Array(bytes.prefix(i))
                    }
                    if bytes.isEmpty { bytes = [0] }
                }
                check(Data(bytes))
            }
        }
    }

    @Test func randomBytesNeverTrap() {
        var random = SplitMix(state: 7)
        for size in [0, 1, 3, 4, 5, 100, 9000, 70_000] {
            for _ in 0..<20 { check(Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &random) })) }
        }
        check(Data(repeating: 13, count: 20_000))
        check(Data("GET / HTTP/1.1\r\nContent-Length: 65536\r\n\r\n".utf8) + Data(repeating: 65, count: 65536))
    }

    @Test func partsOfARequestWaitForMore() {
        for seed in Self.seeds {
            let data = Data(seed.utf8)
            guard case .request = HTTPRequest.parse(data) else { continue }
            for end in 0..<data.count { #expect(HTTPRequest.parse(data.prefix(end)) == .incomplete, "\(seed) at \(end)") }
        }
    }
}
