import Foundation
import Testing
@testable import Remote

private func parse(_ text: String) -> HTTPRequest.Parse { HTTPRequest.parse(Data(text.utf8)) }

private func request(_ text: String) throws -> HTTPRequest {
    guard case .request(let r, _) = parse(text) else { throw CancellationError() }
    return r
}

@Suite struct HTTPParserTests {
    @Test func parsesRequestWithBody() throws {
        let text = "POST /api/command/seek?time=12 HTTP/1.1\r\nHost: mac.local:8686\r\nContent-Length: 13\r\nCookie: a=1; musicsync_token=abc\r\n\r\n{\"time\": 30} "
        guard case .request(let r, let used) = parse(text) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST")
        #expect(r.path == ["api", "command", "seek"])
        #expect(r.headers["host"] == "mac.local:8686")
        #expect(r.body.count == 13)
        #expect(used == text.utf8.count)
        #expect(r.token == "abc")
        #expect(r.parameters["time"] == "12")  // the query wins over the body
    }

    @Test func decodesPathSegmentsAndQuery() throws {
        let r = try request("GET /cover/al%2F1?x=a%20b&x=2 HTTP/1.1\r\n\r\n")
        #expect(r.path == ["cover", "al/1"])
        #expect(r.query == ["x": "a b"])
    }

    @Test func waitsForMoreBytes() {
        #expect(parse("GET / HTTP/1.1\r\nHost: x") == .incomplete)
        #expect(parse("POST /api/pair HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}") == .incomplete)
        #expect(parse("") == .incomplete)
    }

    @Test func rejectsMalformed() {
        let bad = ["GET\r\n\r\n", "get / HTTP/1.1\r\n\r\n", "GET / HTTP/2\r\n\r\n", "GET http://x/ HTTP/1.1\r\n\r\n",
                   "GET / HTTP/1.1 extra\r\n\r\n", "GET / HTTP/1.1\r\nNoColon\r\n\r\n", "GET / HTTP/1.1\r\n: v\r\n\r\n",
                   "GET / HTTP/1.1\r\nBad Name: v\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
                   "POST / HTTP/1.1\r\nContent-Length: x\r\n\r\n"]
        for text in bad { #expect(parse(text) == .invalid(.badRequest), "\(text)") }
        #expect(parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .invalid(.notImplemented))
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n") == .invalid(.payloadTooLarge))
        #expect(parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 9000)) == .invalid(.headersTooLarge))
        #expect(HTTPRequest.parse(Data([0x47, 0x45, 0x54, 0x20, 0xff, 0xfe, 13, 10, 13, 10])) == .invalid(.headersTooLarge))
    }

    @Test func readsBearerToken() throws {
        let r = try request("GET /api/state HTTP/1.1\r\nAuthorization: Bearer  t1 \r\nCookie: musicsync_token=t2\r\n\r\n")
        #expect(r.token == "t1")
    }

    @Test func readsJSONParameters() throws {
        let r = try request("POST /api/command/shuffle HTTP/1.1\r\nContent-Length: 27\r\n\r\n{\"on\":true,\"x\":[1],\"n\":0.5}")
        #expect(r.parameters == ["on": "1", "n": "0.5"])
    }
}

@Suite struct ResponseTests {
    @Test func serializes() {
        let text = String(decoding: HTTPResponse.error(.unauthorized).data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(text.contains("Content-Length: 24\r\n"))
        #expect(text.contains("Cache-Control: no-store\r\n"))
        #expect(text.contains("X-Content-Type-Options: nosniff\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"error\":\"Unauthorized\"}"))
    }

    @Test func framesEvents() {
        #expect(String(decoding: ServerSentEvent.frame("state", "{\"a\":1}"), as: UTF8.self) == "event: state\ndata: {\"a\":1}\n\n")
        #expect(String(decoding: ServerSentEvent.frame("st\nate", "a\nb\r\nc"), as: UTF8.self) == "event: state\ndata: a\ndata: b\ndata: c\n\n")
    }
}

@Suite struct RouteTests {
    private func route(_ text: String) throws -> Result<RemoteRoute, HTTPStatus> { RemoteRoute.parse(try request(text)) }

    @Test func routesEveryForm() throws {
        #expect(try route("GET / HTTP/1.1\r\n\r\n") == .success(.page))
        #expect(try route("GET /manifest.webmanifest HTTP/1.1\r\n\r\n") == .success(.manifest))
        #expect(try route("GET /apple-touch-icon.png HTTP/1.1\r\n\r\n") == .success(.icon))
        #expect(try route("GET /pair?t=abc HTTP/1.1\r\n\r\n") == .success(.page))  // the page pairs with a POST
        #expect(try route("POST /api/pair?link=abc HTTP/1.1\r\n\r\n") == .success(.pairLink("abc", name: "")))
        #expect(try route("GET /silence.wav HTTP/1.1\r\n\r\n") == .success(.silence))
        #expect(try route("GET /api/lyrics HTTP/1.1\r\n\r\n") == .success(.lyrics))
        #expect(try route("GET /api/browse/artist HTTP/1.1\r\n\r\n") == .success(.list(.artist, offset: 0)))
        #expect(try route("GET /api/browse/mix?offset=100 HTTP/1.1\r\n\r\n") == .success(.list(.mix, offset: 100)))
        #expect(try route("GET /api/browse/album/al%2F1?offset=5 HTTP/1.1\r\n\r\n") == .success(.detail(.album, id: "al/1", offset: 5)))
        #expect(try route("POST /api/play/song/s1?mode=next HTTP/1.1\r\n\r\n") == .success(.play(.song, id: "s1", mode: .next, start: 0)))
        #expect(try route("POST /api/play/mix/daily-1?mode=last HTTP/1.1\r\n\r\n") == .success(.play(.mix, id: "daily-1", mode: .last, start: 0)))
        #expect(try route("GET /cover/al-1 HTTP/1.1\r\n\r\n") == .success(.cover("al-1")))
        #expect(try route("POST /api/pair?code=123456&name=iPhone HTTP/1.1\r\n\r\n") == .success(.pair(code: "123456", name: "iPhone")))
        #expect(try route("GET /api/state HTTP/1.1\r\n\r\n") == .success(.state))
        #expect(try route("GET /api/events HTTP/1.1\r\n\r\n") == .success(.events))
        #expect(try route("GET /api/search?q=abba HTTP/1.1\r\n\r\n") == .success(.search("abba")))
        #expect(try route("POST /api/play/album/al%2F1 HTTP/1.1\r\n\r\n") == .success(.play(.album, id: "al/1", mode: .now, start: 0)))
        let body = "POST /api/play/playlist/p1 HTTP/1.1\r\nContent-Length: 12\r\n\r\n{\"start\":42}"
        #expect(try route(body) == .success(.play(.playlist, id: "p1", mode: .now, start: 42)))
    }

    @Test func parsesCommands() throws {
        let cases: [(String, RemoteCommand)] = [
            ("toggle", .toggle), ("play", .play), ("pause", .pause), ("next", .next), ("previous", .previous), ("star", .star),
            ("shuffle", .shuffle(nil)), ("shuffle?on=true", .shuffle(true)), ("shuffle?on=0", .shuffle(false)),
            ("repeat", .repeatMode(nil)), ("repeat?mode=one", .repeatMode(.one)), ("seek?time=42.5", .seek(42.5)),
            ("volume?value=1.7", .volume(1)), ("volume?value=-1", .volume(0)), ("queue?offset=3&id=s1", .playQueue(offset: 3, id: "s1")),
            ("remove?offset=2&id=s3", .removeQueue(offset: 2, id: "s3")), ("move?from=4&to=0&id=s5", .moveQueue(from: 4, to: 0, id: "s5")),
            ("move?from=0&to=3", .moveQueue(from: 0, to: 3, id: nil)), ("output?server=1", .output(server: true)), ("output?server=off", .output(server: false)),
        ]
        for (path, command) in cases {
            #expect(try route("POST /api/command/\(path) HTTP/1.1\r\n\r\n") == .success(.command(command)), "\(path)")
        }
        for bad in ["stop", "seek", "seek?time=-1", "seek?time=nan", "volume?value=x", "shuffle?on=maybe", "repeat?mode=x", "queue?offset=-1",
                    "queue?offset=9223372036854775807", "seek?time=1e999", "remove", "remove?offset=-2", "move?from=1", "move?from=1&to=x",
                    "output", "output?server=maybe"] {
            #expect(try route("POST /api/command/\(bad) HTTP/1.1\r\n\r\n") == .failure(.badRequest), "\(bad)")
        }
        let body = "POST /api/command/seek HTTP/1.1\r\nContent-Length: 11\r\n\r\n{\"time\":30}"
        #expect(try route(body) == .success(.command(.seek(30))))
    }

    @Test func rejectsWrongMethodsAndPaths() throws {
        #expect(try route("GET /api/command/next HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))
        #expect(try route("POST /api/state HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))
        #expect(try route("DELETE / HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))
        #expect(try route("GET /etc/passwd HTTP/1.1\r\n\r\n") == .failure(.notFound))
        #expect(try route("GET /cover/a/b HTTP/1.1\r\n\r\n") == .failure(.notFound))
        #expect(try route("POST /pair?t=abc HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))
        #expect(try route("POST /api/pair HTTP/1.1\r\n\r\n") == .failure(.badRequest))
        #expect(try route("GET /api/play/album/a HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))  // no state change by GET
        #expect(try route("POST /api/browse/album HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))
        #expect(try route("POST /api/lyrics HTTP/1.1\r\n\r\n") == .failure(.methodNotAllowed))
        for bad in ["GET /api/browse/song", "GET /api/browse/genre", "GET /api/browse/song/s1", "GET /api/browse/album?offset=-1",
                    "POST /api/play/genre/g1", "POST /api/play/album/a?mode=soon", "POST /api/play/album/a?start=-1"] {
            #expect(try route("\(bad) HTTP/1.1\r\n\r\n") == .failure(.badRequest), "\(bad)")
        }
    }

    @Test func checksOrigin() throws {
        let host = "POST /api/command/next HTTP/1.1\r\nHost: mac.local:8686\r\n"
        #expect(try route(host + "Origin: http://mac.local:8686\r\n\r\n") == .success(.command(.next)))
        #expect(try route(host + "\r\n") == .success(.command(.next)))
        #expect(try route(host + "Origin: http://evil.example\r\n\r\n") == .failure(.forbidden))
        #expect(try route(host + "Origin: null\r\n\r\n") == .failure(.forbidden))
        #expect(try route("POST /api/command/next HTTP/1.1\r\nOrigin: http://mac.local:8686\r\n\r\n") == .failure(.forbidden))
    }

    @Test func servesLocalNamesOnly() throws {
        for host in ["mac.local:8686", "MAC.LOCAL", "192.168.1.5:8686", "127.0.0.1", "localhost:8686", "[fe80::1]:8686"] {
            #expect(try route("GET /api/state HTTP/1.1\r\nHost: \(host)\r\n\r\n") == .success(.state), "\(host)")
        }
        // A rebound name of another site: same origin to the browser, but not this Mac's name.
        for host in ["evil.example:8686", "evil.example", "local", "x.local.evil.example", ":8686"] {
            let text = "GET /api/state HTTP/1.1\r\nHost: \(host)\r\nOrigin: http://\(host)\r\n\r\n"
            #expect(try route(text) == .failure(.forbidden), "\(host)")
        }
    }
}

@Suite struct AccessTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func decide(_ access: inout RemoteAccess, _ text: String, at time: Date? = nil) throws -> RemoteAccess.Decision {
        access.decide(try request(text), now: time ?? now)
    }

    private func status(_ d: RemoteAccess.Decision) -> Int? {
        if case .respond(let r) = d { return r.status.code }
        return nil
    }

    @Test func needsToken() throws {
        var access = RemoteAccess()
        let token = access.tokens.pair(name: "iPhone", now: now)
        for path in ["GET /api/state", "GET /api/events", "GET /cover/c1", "GET /api/search?q=a", "POST /api/command/next", "POST /api/play/album/a",
                     "GET /api/lyrics", "GET /api/browse/artist", "GET /api/browse/album/a", "GET /silence.wav", "POST /api/command/move?from=0&to=1"] {
            #expect(status(try decide(&access, "\(path) HTTP/1.1\r\n\r\n")) == 401, "\(path)")
            #expect(status(try decide(&access, "\(path) HTTP/1.1\r\nAuthorization: Bearer wrong\r\n\r\n")) == 401, "\(path)")
            #expect(status(try decide(&access, "\(path) HTTP/1.1\r\nCookie: musicsync_token=\r\n\r\n")) == 401, "\(path)")
        }
        let ok = try decide(&access, "GET /api/state HTTP/1.1\r\nCookie: musicsync_token=\(token)\r\n\r\n")
        guard case .serve(.state, let device?) = ok else { Issue.record("not served"); return }
        #expect(device.name == "iPhone")
        #expect(try decide(&access, "GET / HTTP/1.1\r\n\r\n") == .serve(.page, device: nil))
    }

    @Test func pairsWithCodeOnce() throws {
        var access = RemoteAccess()
        #expect(status(try decide(&access, "POST /api/pair?code=000000 HTTP/1.1\r\n\r\n")) == 403)  // window closed
        access.gate.open(now: now)
        let code = access.gate.code
        #expect(code.count == 6)
        let d = try decide(&access, "POST /api/pair?code=\(code)&name=Phone HTTP/1.1\r\n\r\n")
        guard case .respond(let r) = d else { Issue.record("no response"); return }
        #expect(r.status == .ok)
        #expect(r.header("Set-Cookie")?.contains("HttpOnly; SameSite=Strict") == true)
        let token = try #require(try JSONDecoder().decode([String: String].self, from: r.body)["token"])
        #expect(access.tokens.device(for: token)?.name == "Phone")
        #expect(access.tokensChanged)
        #expect(status(try decide(&access, "POST /api/pair?code=\(code) HTTP/1.1\r\n\r\n")) == 403)  // used up
    }

    @Test func pairsWithLink() throws {
        var access = RemoteAccess()
        access.gate.open(now: now)
        let link = access.gate.linkToken
        // Opening the link only shows the page; a link preview or prefetch pairs nothing.
        #expect(try decide(&access, "GET /pair?t=\(link) HTTP/1.1\r\n\r\n") == .serve(.page, device: nil))
        #expect(access.tokens.devices.isEmpty)
        let d = try decide(&access, "POST /api/pair?link=\(link) HTTP/1.1\r\nUser-Agent: Mozilla (iPhone; CPU iPhone OS 18)\r\n\r\n")
        guard case .respond(let r) = d else { Issue.record("no response"); return }
        #expect(r.status == .ok && r.header("Set-Cookie") != nil)
        #expect(access.tokens.devices.map(\.name) == ["iPhone"])
        #expect(status(try decide(&access, "POST /api/pair?link=\(link) HTTP/1.1\r\n\r\n")) == 403)  // used up
        access.gate.open(now: now)
        #expect(status(try decide(&access, "POST /api/pair?link=\(access.gate.code) HTTP/1.1\r\n\r\n")) == 401)  // a code is not a link
    }

    @Test func limitsAttempts() throws {
        var access = RemoteAccess()
        access.gate.open(now: now)
        let first = access.gate.code
        let wrong = first == "111111" ? "222222" : "111111"
        for _ in 0..<PairingGate.maxFailures {
            #expect(status(try decide(&access, "POST /api/pair?code=\(wrong) HTTP/1.1\r\n\r\n")) == 401)
        }
        #expect(access.gate.code != first)  // replaced after the failures
        let code = access.gate.code
        #expect(status(try decide(&access, "POST /api/pair?code=\(code) HTTP/1.1\r\n\r\n")) == 429)
        let later = now.addingTimeInterval(PairingGate.failureWindow + 1)
        #expect(status(try decide(&access, "POST /api/pair?code=\(code) HTTP/1.1\r\n\r\n", at: later)) == 200)
    }

    @Test func windowExpires() throws {
        var access = RemoteAccess()
        access.gate.open(now: now)
        let late = now.addingTimeInterval(PairingGate.window + 1)
        #expect(status(try decide(&access, "POST /api/pair?code=\(access.gate.code) HTTP/1.1\r\n\r\n", at: late)) == 403)
    }

    @Test func revokesAndTouches() {
        var store = TokenStore()
        let a = store.pair(name: "  A\n ", now: now)
        let b = store.pair(name: "", now: now)
        #expect(store.devices.map(\.name) == ["A", "Device"])
        #expect(a != b && a.count == 64)
        let id = store.device(for: a)!.id
        let soon = store.touch(id, now: now.addingTimeInterval(30)), later = store.touch(id, now: now.addingTimeInterval(120))
        #expect(!soon && later)
        store.revoke(id)
        #expect(store.device(for: a) == nil)
        #expect(store.device(for: b) != nil)
        let saved = try? JSONDecoder().decode([PairedDevice].self, from: JSONEncoder().encode(store.devices))
        #expect(saved == store.devices)
        #expect(!(String(data: (try? JSONEncoder().encode(store.devices)) ?? Data(), encoding: .utf8) ?? "").contains(b))
    }
}

@Suite struct StateTests {
    @Test func encodes() throws {
        let item = RemoteState.Item(id: "s1", title: "Song", artist: "A", album: nil, coverArt: "al-1/x")
        var state = RemoteState(song: item, elapsed: .nan, duration: 200, playing: true, volume: 0.5, shuffle: false,
                                repeatMode: .all, starred: true, queue: Array(repeating: item, count: 30))
        #expect(state.queue.count == 30)
        #expect(RemoteState(song: nil, elapsed: 0, duration: 0, playing: false, volume: 1, shuffle: false, repeatMode: .off, starred: false,
                            queue: Array(repeating: item, count: 150)).queue.count == RemoteState.queueLimit)
        #expect(state.elapsed == 0)
        state.output = "AirPlay Speaker"
        state.jukebox = false
        let json = state.json
        #expect(json.contains("\"output\":\"AirPlay Speaker\"") && json.contains("\"jukebox\":false"))
        #expect(json.contains("\"repeat\":\"all\""))
        #expect(json.contains("\"cover\":\"\\/cover\\/al-1%2Fx\""))
        #expect(try JSONDecoder().decode(RemoteState.self, from: Data(json.utf8)) == state)
    }

    @Test func localAddresses() {
        for local: [UInt8] in [[127, 0, 0, 1], [10, 1, 2, 3], [172, 16, 0, 1], [172, 31, 9, 9], [192, 168, 1, 5], [169, 254, 1, 1],
                               Array(repeating: 0, count: 15) + [1], [0xfe, 0x80] + Array(repeating: 0, count: 14),
                               [0xfd, 1] + Array(repeating: 0, count: 14), Array(repeating: 0, count: 10) + [0xff, 0xff, 192, 168, 0, 2]] {
            #expect(LocalAddress.isLocal(local), "\(local)")
        }
        for remote: [UInt8] in [[8, 8, 8, 8], [172, 32, 0, 1], [100, 64, 0, 1], [1, 2, 3], [0x20, 1] + Array(repeating: 0, count: 14),
                                Array(repeating: 0, count: 10) + [0xff, 0xff, 8, 8, 8, 8]] {
            #expect(!LocalAddress.isLocal(remote), "\(remote)")
        }
    }
}

@Suite struct RemoteServerTests {
    @Test func slowAnswerOutlivesTheRequestTimeout() async throws {
        let port = UInt16.random(in: 42000...48000)
        let server = RemoteServer(port: port, name: "Test") { _ in
            try? await Task.sleep(for: .milliseconds(600))  // a cover from a slow music server
            return .response(HTTPResponse(headers: [("Content-Type", "text/plain")], body: Data("ok".utf8)))
        }
        server.requestTimeout = 0.2
        try server.start { _ in }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/manifest.webmanifest")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
    }

    @Test func silentClientIsClosed() async throws {
        let port = UInt16.random(in: 48001...54000)
        let server = RemoteServer(port: port, name: "Test") { _ in .response(.error(.notFound)) }
        server.requestTimeout = 0.2
        try server.start { _ in }
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(200))
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        // A busy machine may start listening late: try again for up to 2 s.
        var fd: Int32 = -1, connected: Int32 = -1
        for _ in 0..<20 where connected != 0 {
            if fd >= 0 { close(fd); try await Task.sleep(for: .milliseconds(100)) }
            fd = socket(AF_INET, SOCK_STREAM, 0)
            connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        defer { close(fd) }
        #expect(connected == 0)
        var byte: UInt8 = 0
        #expect(read(fd, &byte, 1) == 0)  // the server closes the connection after the timeout
    }
}
