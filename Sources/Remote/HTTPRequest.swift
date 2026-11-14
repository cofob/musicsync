import Foundation

/// One parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// Decoded path segments: `/api/play/album/a%2Fb` gives `["api", "play", "album", "a/b"]`.
    public var path: [String]
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: [String], query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public enum Parse: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        /// A full request and the number of bytes it used.
        case request(HTTPRequest, consumed: Int)
        /// A bad request: answer with this status and close.
        case invalid(HTTPStatus)
    }

    /// Small limits: the remote sends short requests only.
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 64 * 1024

    public static func parse(_ data: Data) -> Parse {
        let bytes = [UInt8](data)
        guard let end = headerEnd(bytes) else { return bytes.count > maxHeaderBytes ? .invalid(.headersTooLarge) : .incomplete }
        guard end <= maxHeaderBytes, let head = String(bytes: bytes[..<end], encoding: .utf8) else { return .invalid(.headersTooLarge) }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              parts[1].hasPrefix("/"), let target = URLComponents(string: String(parts[1])) else { return .invalid(.badRequest) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .invalid(.badRequest) }
            let name = line[..<colon].lowercased()
            guard !name.contains(" ") else { return .invalid(.badRequest) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(.notImplemented) }
        var length = 0
        if let text = headers["content-length"] {
            guard let n = Int(text), n >= 0 else { return .invalid(.badRequest) }
            guard n <= maxBodyBytes else { return .invalid(.payloadTooLarge) }
            length = n
        }
        let start = end + 4
        guard bytes.count >= start + length else { return .incomplete }
        let path = target.percentEncodedPath.split(separator: "/").compactMap { $0.removingPercentEncoding }
        var query: [String: String] = [:]
        for item in target.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: Data(bytes[start..<start + length]))
        return .request(request, consumed: start + length)
    }

    /// Index of the blank line (`\r\n\r\n`) that ends the headers.
    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return i }
        return nil
    }

    /// Value of one cookie from the `Cookie` header.
    public func cookie(_ name: String) -> String? {
        for pair in (headers["cookie"] ?? "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == name { return kv[1] }
        }
        return nil
    }

    /// Token from `Authorization: Bearer …`, else from the cookie.
    public var token: String? {
        if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return cookie(RemoteAuth.cookieName)
    }

    /// Parameters from the query, then from a flat JSON object body (`{"time": 30}`); the query wins.
    /// JSON `true` / `false` read as "1" / "0".
    public var parameters: [String: String] {
        var result: [String: String] = [:]
        if !body.isEmpty, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for (key, value) in object {
                if let n = value as? NSNumber { result[key] = n.stringValue } else if let s = value as? String { result[key] = s }
            }
        }
        return result.merging(query) { _, q in q }
    }
}
