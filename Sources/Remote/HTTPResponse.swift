import Foundation

public struct HTTPStatus: Error, Sendable, Equatable {
    public let code: Int
    public let reason: String

    public static let ok = HTTPStatus(code: 200, reason: "OK")
    public static let noContent = HTTPStatus(code: 204, reason: "No Content")
    public static let partialContent = HTTPStatus(code: 206, reason: "Partial Content")
    public static let badRequest = HTTPStatus(code: 400, reason: "Bad Request")
    public static let unauthorized = HTTPStatus(code: 401, reason: "Unauthorized")
    public static let forbidden = HTTPStatus(code: 403, reason: "Forbidden")
    public static let notFound = HTTPStatus(code: 404, reason: "Not Found")
    public static let methodNotAllowed = HTTPStatus(code: 405, reason: "Method Not Allowed")
    public static let conflict = HTTPStatus(code: 409, reason: "Conflict")
    public static let payloadTooLarge = HTTPStatus(code: 413, reason: "Payload Too Large")
    public static let tooManyRequests = HTTPStatus(code: 429, reason: "Too Many Requests")
    public static let rangeNotSatisfiable = HTTPStatus(code: 416, reason: "Range Not Satisfiable")
    public static let headersTooLarge = HTTPStatus(code: 431, reason: "Request Header Fields Too Large")
    public static let notImplemented = HTTPStatus(code: 501, reason: "Not Implemented")
    public static let unavailable = HTTPStatus(code: 503, reason: "Service Unavailable")
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: HTTPStatus
    public var headers: [(String, String)]
    public var body: Data

    public init(_ status: HTTPStatus = .ok, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { "\($0.0): \($0.1)" } == b.headers.map { "\($0.0): \($0.1)" }
    }

    public func header(_ name: String) -> String? { headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

    public static func json(_ value: some Encodable, status: HTTPStatus = .ok) -> HTTPResponse {
        HTTPResponse(status, headers: [("Content-Type", "application/json; charset=utf-8")], body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    /// `{"error": "…"}` with the status.
    public static func error(_ status: HTTPStatus) -> HTTPResponse { json(["error": status.reason], status: status) }

    /// Same-origin only; no framing, no sniffing, no referrer (the page URL may hold a pairing token).
    static let securityHeaders = [
        ("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]

    /// Wire form; the connection closes after it, so `Content-Length` frames the body.
    public var data: Data {
        var head = "HTTP/1.1 \(status.code) \(status.reason)\r\n"
        var all = headers
        if header("Cache-Control") == nil { all.append(("Cache-Control", "no-store")) }
        all += Self.securityHeaders + [("Content-Length", String(body.count)), ("Connection", "close")]
        for (name, value) in all { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    /// Head of a Server-Sent Events stream; events follow on the same connection.
    public static let eventStreamHead = Data((
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        + "Connection: keep-alive\r\n\r\n").utf8)
}

/// Server-Sent Events framing.
public enum ServerSentEvent {
    /// `event: <name>` and one `data:` line per line of `data`, ended by a blank line.
    public static func frame(_ name: String, _ data: String) -> Data {
        let clean = name.filter { !$0.isNewline }
        let lines = data.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        return Data(("event: \(clean)\n" + lines.map { "data: \($0)\n" }.joined() + "\n").utf8)
    }

    /// Keeps the connection open through idle periods, and lets the page see a stream that died while the phone slept.
    public static let ping = frame("ping", "")
}
