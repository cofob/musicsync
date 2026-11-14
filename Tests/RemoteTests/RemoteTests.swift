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
        #expect(try route("GET /pair?t=abc HTTP/1.1\r\n\r\n") == .success(.pairLink("abc")))
        #expect(try route("GET /cover/al-1 HTTP/1.1\r\n\r\n") == .success(.cover("al-1")))
        #expect(try route("POST /api/pair?code=123456&name=iPhone HTTP/1.1\r\n\r\n") == .success(.pair(code: "123456", name: "iPhone")))
        #expect(try route("GET /api/state HTTP/1.1\r\n\r\n") == .success(.state))
        #expect(try route("GET /api/events HTTP/1.1\r\n\r\n") == .success(.events))
        #expect(try route("GET /api/search?q=abba HTTP/1.1\r\n\r\n") == .success(.search("abba")))
        #expect(try route("POST /api/play/album/al%2F1 HTTP/1.1\r\n\r\n") == .success(.playAlbum("al/1")))
        #expect(try route("POST /api/play/playlist/p1 HTTP/1.1\r\n\r\n") == .success(.playPlaylist("p1")))
    }

    @Test func parsesCommands() throws {
        let cases: [(String, RemoteCommand)] = [
            ("toggle", .toggle), ("play", .play), ("pause", .pause), ("next", .next), ("previous", .previous), ("star", .star),
            ("shuffle", .shuffle(nil)), ("shuffle?on=true", .shuffle(true)), ("shuffle?on=0", .shuffle(false)),
            ("repeat", .repeatMode(nil)), ("repeat?mode=one", .repeatMode(.one)), ("seek?time=42.5", .seek(42.5)),
            ("volume?value=1.7", .volume(1)), ("volume?value=-1", .volume(0)), ("queue?offset=3&id=s1", .playQueue(offset: 3, id: "s1")),
        ]
        for (path, command) in cases {
            #expect(try route("POST /api/command/\(path) HTTP/1.1\r\n\r\n") == .success(.command(command)), "\(path)")
        }
        for bad in ["stop", "seek", "seek?time=-1", "seek?time=nan", "volume?value=x", "shuffle?on=maybe", "repeat?mode=x", "queue?offset=-1",
                    "queue?offset=9223372036854775807", "seek?time=1e999"] {
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
        #expect(try route("GET /pair HTTP/1.1\r\n\r\n") == .failure(.badRequest))
        #expect(try route("POST /api/pair HTTP/1.1\r\n\r\n") == .failure(.badRequest))
    }

    @Test func checksOrigin() throws {
        let host = "POST /api/command/next HTTP/1.1\r\nHost: mac.local:8686\r\n"
        #expect(try route(host + "Origin: http://mac.local:8686\r\n\r\n") == .success(.command(.next)))
        #expect(try route(host + "\r\n") == .success(.command(.next)))
        #expect(try route(host + "Origin: http://evil.example\r\n\r\n") == .failure(.forbidden))
        #expect(try route(host + "Origin: null\r\n\r\n") == .failure(.forbidden))
        #expect(try route("POST /api/command/next HTTP/1.1\r\nOrigin: http://mac.local:8686\r\n\r\n") == .failure(.forbidden))
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
        for path in ["GET /api/state", "GET /api/events", "GET /cover/c1", "GET /api/search?q=a", "POST /api/command/next", "POST /api/play/album/a"] {
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
        let d = try decide(&access, "GET /pair?t=\(link) HTTP/1.1\r\nUser-Agent: Mozilla (iPhone; CPU iPhone OS 18)\r\n\r\n")
        guard case .respond(let r) = d else { Issue.record("no response"); return }
        #expect(r.status == .seeOther && r.header("Location") == "/")
        #expect(access.tokens.devices.map(\.name) == ["iPhone"])
        guard case .respond(let again) = try decide(&access, "GET /pair?t=\(link) HTTP/1.1\r\n\r\n") else { return }
        #expect(again.status == .seeOther && again.header("Set-Cookie") == nil)
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
        let state = RemoteState(song: item, elapsed: .nan, duration: 200, playing: true, volume: 0.5, shuffle: false,
                                repeatMode: .all, starred: true, queue: Array(repeating: item, count: 30))
        #expect(state.queue.count == 20)
        #expect(state.elapsed == 0)
        let json = state.json
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
