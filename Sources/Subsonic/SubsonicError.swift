import Foundation

public enum SubsonicError: Error, LocalizedError, Equatable, Sendable {
    /// `status=failed` reply from the server.
    case api(code: Int, message: String)
    case badStatus(Int)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .api(let code, let message): "Server error \(code): \(message)"
        case .badStatus(let status): "HTTP status \(status)"
        case .badResponse(let what): "Unexpected server reply: \(what)"
        }
    }
}
