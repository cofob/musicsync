import Foundation

/// Routing, pairing and token checks in one place, before the app acts on a request.
public struct RemoteAccess: Sendable {
    public var tokens: TokenStore
    public var gate = PairingGate()
    /// Set when `tokens` changed and should be saved.
    public private(set) var tokensChanged = false

    public init(tokens: TokenStore = TokenStore()) { self.tokens = tokens }

    public enum Decision: Equatable, Sendable {
        /// Answer at once.
        case respond(HTTPResponse)
        /// The app serves the route; `device` is nil for the public routes (page, manifest, icon).
        case serve(RemoteRoute, device: PairedDevice?)
    }

    public mutating func decide(_ request: HTTPRequest, now: Date = Date()) -> Decision {
        let route: RemoteRoute
        switch RemoteRoute.parse(request) {
        case .failure(let status): return .respond(.error(status))
        case .success(let r): route = r
        }
        switch route {
        case .pair(let code, let name), .pairLink(let code, let name):
            let isLink = if case .pairLink = route { true } else { false }
            let outcome = isLink ? gate.attempt(link: code, now: now) : gate.attempt(code: code, now: now)
            guard outcome == .paired else { return .respond(.error(Self.status(outcome))) }
            let token = pair(name.isEmpty ? Self.deviceName(request) : name, now: now)
            var response = HTTPResponse.json(["token": token])
            response.headers.append(RemoteAuth.cookie(token))
            return .respond(response)
        case let r where !r.needsToken:
            return .serve(r, device: nil)
        default:
            guard let device = tokens.device(for: request.token) else { return .respond(.error(.unauthorized)) }
            if tokens.touch(device.id, now: now) { tokensChanged = true }
            return .serve(route, device: device)
        }
    }

    /// Call after saving `tokens`.
    public mutating func saved() { tokensChanged = false }

    private mutating func pair(_ name: String, now: Date) -> String {
        tokensChanged = true
        return tokens.pair(name: name, now: now)
    }

    private static func status(_ outcome: PairingGate.Outcome) -> HTTPStatus {
        switch outcome {
        case .paired: .ok
        case .wrong: .unauthorized
        case .closed: .forbidden
        case .limited: .tooManyRequests
        }
    }

    /// A rough device name from the browser, for the Paired Devices list.
    static func deviceName(_ request: HTTPRequest) -> String {
        let agent = request.headers["user-agent"] ?? ""
        for name in ["iPhone", "iPad", "Watch", "Android", "Mac"] where agent.contains(name) { return name == "Watch" ? "Apple Watch" : name }
        return "Browser"
    }
}
