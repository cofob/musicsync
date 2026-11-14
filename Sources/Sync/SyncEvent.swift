import Foundation

public enum SyncPhase: String, Sendable {
    case preparing, backingUp, readingDevice, removing, transferring, artwork, playlists, writing, scrobbling, ejecting
}

public enum ItemStage: Sendable, Equatable {
    case queued
    /// Bytes received and expected (0 = unknown).
    case downloading(Int64, Int64)
    /// 0...1
    case transcoding(Double)
    case copying, done
    case failed(String)
}

public struct SyncProgress: Sendable, Equatable {
    public var itemsDone = 0, itemsTotal = 0
    public var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
}

public struct SyncSummary: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var songID: String
        public var title: String
        public var message: String
    }

    public var added = 0, reencoded = 0, retagged = 0, removed = 0
    public var failures: [Failure] = []
    public var scrobblesSent = 0, scrobblesPending = 0
    public var cancelled = false
}

public enum SyncEvent: Sendable {
    case phase(SyncPhase)
    case item(songID: String, title: String, stage: ItemStage)
    case progress(SyncProgress)
    case warning(String)
    case finished(SyncSummary)
}
