import Foundation
import Support

/// Server address and user. The password lives in the Keychain.
public struct ServerConfig: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var username: String

    public init(baseURL: URL, username: String) {
        self.baseURL = baseURL
        self.username = username
    }

    /// Keychain account name: `user@host`.
    public var account: String { "\(username)@\(baseURL.host ?? baseURL.absoluteString)" }

    public var password: String? { Keychain.get(account) }

    @discardableResult
    public func setPassword(_ password: String) -> Bool { Keychain.set(password, for: account) }
}
