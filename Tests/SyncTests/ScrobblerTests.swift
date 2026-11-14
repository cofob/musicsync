import Foundation
import Testing
@testable import Sync

@Suite struct ScrobblerTests {
    @Test func timestampsAreSpacedByTrackLength() {
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        let times = Scrobbler.timestamps(plays: 3, lastPlayed: last, duration: 200)
        #expect(times == [last, last.addingTimeInterval(-200), last.addingTimeInterval(-400)])
        #expect(Scrobbler.timestamps(plays: 2, lastPlayed: last, duration: 0).last == last.addingTimeInterval(-1))
        #expect(Scrobbler.timestamps(plays: 0, lastPlayed: last, duration: 200).isEmpty)
        #expect(Scrobbler.timestamps(plays: 5000, lastPlayed: nil, duration: 1).count == 1000)
    }

    @Test func queueSurvivesRestartAndIgnoresRepeatedSource() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("q.json")
        let request = ScrobbleRequest(songID: "s", time: Date(timeIntervalSince1970: 1_700_000_000))
        let first = Scrobbler(queueURL: url)
        await first.enqueue([request], source: Data("play counts".utf8))
        await first.enqueue([request], source: Data("play counts".utf8))
        await first.enqueue([request])
        #expect(await first.pendingCount == 2)
        #expect(await Scrobbler(queueURL: url).pendingCount == 2)
    }

    @Test func flushSendsBatchesOfFiftyAndKeepsFailures() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = StubServer()
        let scrobbler = Scrobbler(queueURL: dir.appendingPathComponent("q.json"))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await scrobbler.enqueue((0..<120).map { ScrobbleRequest(songID: "s\($0)", time: base.addingTimeInterval(Double($0))) })

        server.failScrobblesAfter = 1
        let partial = await scrobbler.flush(client: server.client)
        #expect(partial == FlushResult(sent: 50, pending: 70))

        server.failScrobblesAfter = nil
        let rest = await scrobbler.flush(client: server.client)
        #expect(rest == FlushResult(sent: 70, pending: 0))
        let calls = server.scrobbles
        #expect(calls.map(\.ids.count) == [50, 50, 20])
        #expect(calls[0].ids.first == "s0" && calls[0].times.count == 50)
        #expect(calls.allSatisfy { $0.submission })
    }
}
