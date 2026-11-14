import Foundation
import Testing
@testable import Remote

@Suite struct ListTests {
    @Test func pages() {
        let all = Array(0..<250)
        let item = { (n: Int) in RemoteItem(kind: .album, id: "al-\(n)", name: "A\(n)", detail: nil, coverArt: n == 0 ? "c/0" : nil) }
        let first = RemoteList.page(all, offset: 0, title: "Albums", item: item)
        #expect(first.items.count == RemoteList.pageSize && first.next == 100 && first.items[0].cover == "/cover/c%2F0")
        let last = RemoteList.page(all, offset: 200, title: "Albums", item: item)
        #expect(last.items.map(\.id).first == "al-200" && last.items.count == 50 && last.next == nil)
        #expect(RemoteList.page(all, offset: 999, title: "Albums", item: item).items.isEmpty)
        let json = String(decoding: (try? JSONEncoder().encode(first.items[1])) ?? Data(), as: UTF8.self)
        #expect(json.contains("\"kind\":\"album\""))
    }

    @Test func encodesLyrics() throws {
        let lyrics = RemoteLyrics(id: "s1", lines: [.init(start: 1.5, text: "One"), .init(start: nil, text: "Two")])
        #expect(try JSONDecoder().decode(RemoteLyrics.self, from: JSONEncoder().encode(lyrics)) == lyrics)
    }
}

@Suite struct AudioTests {
    @Test func silenceIsAValidWave() {
        let wav = [UInt8](RemoteAudio.silence)
        #expect(Array(wav[0..<4]) == Array("RIFF".utf8) && Array(wav[8..<16]) == Array("WAVEfmt ".utf8))
        let size = Int(wav[4]) | Int(wav[5]) << 8 | Int(wav[6]) << 16 | Int(wav[7]) << 24
        #expect(size == wav.count - 8)
        #expect(wav[44...].allSatisfy { $0 == 128 })  // 8-bit silence
    }

    @Test func answersRanges() {
        let body = Data((0..<100).map { UInt8($0) })
        let whole = RemoteAudio.ranged(body, type: "audio/wav", range: nil)
        #expect(whole.status == .ok && whole.body == body && whole.header("Accept-Ranges") == "bytes")
        let cases: [(String, Range<Int>)] = [("bytes=0-1", 0..<2), ("bytes=10-", 10..<100), ("bytes=90-500", 90..<100), ("bytes=-5", 95..<100),
                                             ("bytes=-500", 0..<100)]
        for (range, part) in cases {
            let r = RemoteAudio.ranged(body, type: "audio/wav", range: range)
            #expect(r.status == .partialContent && r.body == body.subdata(in: part), "\(range)")
            #expect(r.header("Content-Range") == "bytes \(part.lowerBound)-\(part.upperBound - 1)/100", "\(range)")
        }
        for bad in ["bytes=100-", "bytes=5-2", "bytes=-0", "bytes=x-1", "bytes=-", "bytes=1-x"] {
            let r = RemoteAudio.ranged(body, type: "audio/wav", range: bad)
            #expect(r.status == .rangeNotSatisfiable && r.header("Content-Range") == "bytes */100", "\(bad)")
        }
        #expect(RemoteAudio.ranged(body, type: "audio/wav", range: "items=0-1").status == .ok)
    }
}

@Suite struct PageTests {
    @Test func pingIsAnEventThePageSees() {
        #expect(String(decoding: ServerSentEvent.ping, as: UTF8.self) == "event: ping\ndata: \n\n")
    }

    @Test func pageAsksNothingFromOutside() {
        let page = RemotePage.html
        #expect(page.hasPrefix("<!doctype html>") && page.hasSuffix("</html>\n"))
        #expect(!page.contains("http://") && !page.contains("https://"))
        for hook in ["/api/events", "/api/lyrics", "/api/browse/", "/api/play/", "navigator.mediaSession", "/silence.wav", "/api/pair"] {
            #expect(page.contains(hook), "\(hook)")
        }
    }
}

@Suite struct EventStreamTests {
    /// The stream's `data:` lines until `want` of them came or the stream ended; empty when it did not open in 10 s.
    private func read(_ url: URL, want: Int, onFirst: @escaping @Sendable () -> Void) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            group.addTask {
                var lines: [String] = []
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(from: url)
                    guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream" else { return [] }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        lines.append(line)
                        if lines.count == 1 { onFirst() }
                        if lines.count == want { break }
                    }
                } catch {}
                return lines
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    @Test func streamCarriesTheFirstStateAndBroadcasts() async throws {
        let port = UInt16.random(in: 54001...60000)
        let server = RemoteServer(port: port, name: "Test") { _ in .events(owner: "d1", first: ServerSentEvent.frame("state", "1")) }
        try server.start { _ in }
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/api/events"))
        // A busy machine may start listening late: try again for up to 3 s.
        var lines: [String] = []
        for attempt in 0..<15 where lines.isEmpty {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(200)) }
            lines = await read(url, want: 2) { server.broadcast(ServerSentEvent.frame("state", "2")) }
        }
        #expect(lines == ["data: 1", "data: 2"])
    }

    @Test func revokedDeviceLosesItsStream() async throws {
        let port = UInt16.random(in: 60001...65000)
        let server = RemoteServer(port: port, name: "Test") { _ in .events(owner: "d1", first: ServerSentEvent.frame("state", "1")) }
        try server.start { _ in }
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/api/events"))
        var lines: [String] = []
        for attempt in 0..<15 where lines.isEmpty {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(200)) }
            // The stream ends after the close, so only one line comes before the deadline.
            lines = await read(url, want: 2) { server.closeStreams(owner: "d1") }
        }
        #expect(lines == ["data: 1"])
    }
}
