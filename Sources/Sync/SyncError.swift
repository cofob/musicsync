import Foundation

public enum SyncError: Error, LocalizedError, Equatable, Sendable {
    case noFirewireGuid
    case ffmpegMissing
    case encoderMissing(String)
    case notEnoughSpace
    case alreadyRunning
    case databaseUnreadable(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFirewireGuid:
            "The iPod FireWire GUID is unknown. Without it the iPod shows an empty library. Enter the GUID in Settings."
        case .ffmpegMissing: "ffmpeg/ffprobe not found. Install ffmpeg or set its path in Settings."
        case .encoderMissing(let name): "ffmpeg has no \(name) encoder."
        case .notEnoughSpace: "Not enough free space on the iPod."
        case .alreadyRunning: "A sync is already running."
        case .databaseUnreadable(let why): "The iPod database cannot be read, nothing was changed: \(why)"
        case .verificationFailed(let why): "The new database failed verification, nothing was written: \(why)"
        }
    }
}
