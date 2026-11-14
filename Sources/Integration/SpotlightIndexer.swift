import CoreSpotlight
import Foundation

/// Where index changes go: the system index in the app, a recorder in tests.
public protocol SpotlightSink: Sendable {
    func index(_ entries: [SpotlightEntry]) async throws
    func delete(ids: [String]) async throws
    func deleteAll() async throws
}

/// Keeps the Spotlight index in step with the library. Only changed entries are sent; the last sent state is kept
/// in a file, per server, so a restart does not index everything again.
public actor SpotlightIndexer {
    private struct State: Codable {
        var serverKey: String
        var entries: [String: SpotlightEntry]
    }

    private let sink: SpotlightSink
    private let stateURL: URL
    private var state: State?

    public init(sink: SpotlightSink, stateURL: URL) {
        self.sink = sink
        self.stateURL = stateURL
        state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    /// Sends the difference to the last update. Another server first clears the index.
    public func update(serverKey: String, entries: [SpotlightEntry]) async throws {
        if let state, state.serverKey != serverKey { try await clear() }
        let new = Dictionary(entries.map { ($0.id, $0) }) { _, last in last }
        let plan = SpotlightPlan(old: state?.entries ?? [:], new: Array(new.values))
        if !plan.removals.isEmpty { try await sink.delete(ids: plan.removals) }
        if !plan.upserts.isEmpty { try await sink.index(plan.upserts) }
        state = State(serverKey: serverKey, entries: new)
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    /// Removes everything, e.g. after sign-out or when indexing is turned off.
    public func clear() async throws {
        try await sink.deleteAll()
        state = nil
        try? FileManager.default.removeItem(at: stateURL)
    }
}

/// The app's own named section of the system index.
public struct SystemSpotlight: SpotlightSink, @unchecked Sendable {  // CSSearchableIndex is thread-safe.
    private let index = CSSearchableIndex(name: "MusicSync")

    public init() {}

    public func index(_ entries: [SpotlightEntry]) async throws {
        // Batches keep each call small.
        for start in stride(from: 0, to: entries.count, by: 500) {
            try await index.indexSearchableItems(entries[start..<min(start + 500, entries.count)].map(\.searchableItem))
        }
    }

    public func delete(ids: [String]) async throws { try await index.deleteSearchableItems(withIdentifiers: ids) }
    public func deleteAll() async throws { try await index.deleteAllSearchableItems() }
}
