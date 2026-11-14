import Foundation
import Testing
@testable import Subsonic

struct DownloadTests {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func add(_ v: Int64) { lock.withLock { values.append(v) } }
        var last: Int64? { lock.withLock { values.last } }
    }

    @Test func downloadReportsProgressAndKeepsTheFile() async throws {
        let server = StubServer()
        let source = try tempDirectory("download").appendingPathComponent("song.flac")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        server.serve(songID: "s-1", file: source)
        let seen = Seen()
        let file = try await server.client.download(id: "s-1") { done, _ in seen.add(done) }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(seen.last != nil, "last: \(String(describing: seen.last))")
    }
}
