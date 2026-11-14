import Foundation
import OSLog

private let log = Logger(subsystem: "MusicSync", category: "Errors")

public extension Error {
    /// A short message for the user that says what to do. The raw text goes to the log (and so to Diagnostics).
    var friendlyMessage: String {
        let message = FriendlyError.message(for: self)
        let raw = self as NSError
        log.error("\(message, privacy: .public) [\(raw.domain, privacy: .public) \(raw.code): \(self.localizedDescription, privacy: .public)]")
        return message
    }
}

/// Server and network errors in plain words, in one place.
public enum FriendlyError {
    public static func message(for error: Error) -> String {
        switch error {
        case let error as SubsonicError: message(for: error)
        case let error as URLError: message(for: error.code) ?? error.localizedDescription
        default: error.localizedDescription
        }
    }

    static func message(for error: SubsonicError) -> String {
        switch error {
        case .badStatus(let code): status(code)
        case .badResponse: "The server sent a reply the app cannot read. Try again later."
        case .api(let code, let message): api(code) ?? "The server reported a problem: \(message)"
        }
    }

    static func status(_ status: Int) -> String {
        switch status {
        case 401, 403: "The server refused access (error \(status)). Check your user name and password."
        case 404: "The server does not know this request (error 404). Check the server address."
        case 500: "The server had a problem (error 500). Try again later."
        case 502, 503, 504: "The server is not available now (error \(status)). Try again later."
        default: "The server answered with error \(status). Try again later."
        }
    }

    /// Subsonic error codes.
    static func api(_ code: Int) -> String? {
        switch code {
        case 10: "The server did not understand the request (a parameter is missing). Update the server."
        case 20: "The server is too old for this app. Update the server."
        case 30: "This app is too old for the server. Update MusicSync."
        case 40: "Wrong user name or password. Check them in Settings."
        case 41: "The server does not accept this sign-in method. Check the server settings."
        case 50: "Your account is not allowed to do this. Ask the server administrator."
        case 60: "The server needs a license for this. Ask the server administrator."
        case 70: "The server did not find this item. Refresh the library."
        default: nil
        }
    }

    static func message(for code: URLError.Code) -> String? {
        switch code {
        case .timedOut: "The server did not answer in time. Check your connection and try again."
        case .cannotFindHost, .dnsLookupFailed: "Cannot find the server. Check the server address and your connection."
        case .cannotConnectToHost: "The server refused the connection. Check that it runs and that the address and port are correct."
        case .notConnectedToInternet: "You are offline. Check your connection."
        case .networkConnectionLost: "The connection to the server was lost. Try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
            "Cannot make a secure connection to the server. Check its certificate and whether the address starts with http or https."
        case .appTransportSecurityRequiresSecureConnection: "The server needs a secure address. Use https in the server address."
        default: nil
        }
    }
}
