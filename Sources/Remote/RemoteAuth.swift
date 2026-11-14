import CryptoKit
import Foundation

public enum RemoteAuth {
    public static let cookieName = "musicsync_token"

    /// 32 random bytes as hex; `SystemRandomNumberGenerator` is cryptographically secure.
    public static func newToken() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
    }

    static func hash(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// `Set-Cookie` for a paired browser: one year, not readable by scripts, not sent cross-site.
    public static func cookie(_ token: String) -> (String, String) {
        ("Set-Cookie", "\(cookieName)=\(token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict")
    }
}

/// A paired phone, tablet, watch or Shortcuts token. Only the token hash is kept.
public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    let tokenHash: String
    public let paired: Date
    public var lastSeen: Date
}

/// Paired devices by token hash. Saved by the app (`devices`) as JSON.
public struct TokenStore: Sendable, Equatable {
    public private(set) var devices: [PairedDevice]

    public init(devices: [PairedDevice] = []) { self.devices = devices }

    /// Adds a device and returns its token; the token is not stored.
    public mutating func pair(name: String, now: Date = Date()) -> String {
        let token = RemoteAuth.newToken()
        let clean = String(name.filter { !$0.isNewline }.prefix(60)).trimmingCharacters(in: .whitespaces)
        devices.append(PairedDevice(id: UUID().uuidString, name: clean.isEmpty ? "Device" : clean,
                                    tokenHash: RemoteAuth.hash(token), paired: now, lastSeen: now))
        return token
    }

    /// The device of `token`, nil for a missing or unknown one.
    public func device(for token: String?) -> PairedDevice? {
        guard let token, !token.isEmpty else { return nil }
        let hash = RemoteAuth.hash(token)
        return devices.first { $0.tokenHash == hash }
    }

    /// Marks the device seen; true when the change is worth saving (more than a minute later).
    @discardableResult public mutating func touch(_ id: String, now: Date = Date()) -> Bool {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return false }
        let old = devices[i].lastSeen
        devices[i].lastSeen = now
        return now.timeIntervalSince(old) > 60
    }

    public mutating func revoke(_ id: String) { devices.removeAll { $0.id == id } }
}

/// The pairing window: a 6-digit code and a one-time link token, valid for a few minutes after the
/// user opens it on the Mac. Failed attempts are limited, and too many of them change the code.
public struct PairingGate: Sendable {
    public static let window: TimeInterval = 300
    public static let maxFailures = 5
    public static let failureWindow: TimeInterval = 60

    public private(set) var code = ""
    public private(set) var linkToken = ""
    public private(set) var openUntil: Date?
    private var failures: [Date] = []

    public init() {}

    public enum Outcome: Equatable, Sendable {
        case paired, wrong, closed, limited
    }

    public func isOpen(at now: Date = Date()) -> Bool { openUntil.map { now < $0 } ?? false }

    /// Starts a new pairing window with a new code and link token.
    public mutating func open(now: Date = Date()) {
        var rng = SystemRandomNumberGenerator()
        code = String(format: "%06d", Int.random(in: 0..<1_000_000, using: &rng))
        linkToken = RemoteAuth.newToken()
        openUntil = now.addingTimeInterval(Self.window)
    }

    public mutating func close() { openUntil = nil; code = ""; linkToken = "" }

    /// Checks a typed code; a success closes the window, so each code pairs one device.
    public mutating func attempt(code typed: String, now: Date = Date()) -> Outcome {
        check(typed.filter { !$0.isWhitespace }, against: code, now: now)
    }

    /// Checks the token of a scanned pairing link.
    public mutating func attempt(link typed: String, now: Date = Date()) -> Outcome { check(typed, against: linkToken, now: now) }

    private mutating func check(_ typed: String, against secret: String, now: Date) -> Outcome {
        failures.removeAll { now.timeIntervalSince($0) > Self.failureWindow }
        guard failures.count < Self.maxFailures else { return .limited }
        guard isOpen(at: now), !secret.isEmpty else { return .closed }
        guard Self.equal(typed, secret) else {
            failures.append(now)
            if failures.count >= Self.maxFailures {  // a guessed-at code is replaced; the window keeps its end
                let until = openUntil
                open(now: now)
                openUntil = until
            }
            return .wrong
        }
        close()
        return .paired
    }

    /// Compares in time independent of where the strings differ.
    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
