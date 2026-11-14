import Foundation

enum MirrorError: Error, LocalizedError {
    case aborted(String)
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .aborted(let what), .incomplete(let what): what
        }
    }
}

/// Runs `work` for every item with at most `limit` running at once.
/// `onSuccess` and `onFailure` run on the calling task. The run stops early when the task is cancelled
/// or `maxFailuresInRow` items fail one after another (server down); it returns false in that case.
func forEachBounded<Item: Sendable>(
    _ items: [Item], limit: Int, maxFailuresInRow: Int = 8,
    work: @escaping @Sendable (Item) async throws -> Void,
    onSuccess: () -> Void, onFailure: (Item, Error) -> Void
) async -> Bool {
    var next = items.makeIterator()
    var failuresInRow = 0
    var healthy = true
    await withTaskGroup(of: (Item, Error?).self) { group in
        func launch(into group: inout TaskGroup<(Item, Error?)>) {
            guard healthy, !Task.isCancelled, let item = next.next() else { return }
            group.addTask {
                do { try await work(item); return (item, nil) } catch { return (item, error) }
            }
        }
        for _ in 0..<max(1, limit) { launch(into: &group) }
        while let (item, error) = await group.next() {
            if let error {
                if error is CancellationError || Task.isCancelled { continue }
                failuresInRow += 1
                onFailure(item, error)
                if failuresInRow >= maxFailuresInRow { healthy = false }
            } else {
                failuresInRow = 0
                onSuccess()
            }
            launch(into: &group)
        }
    }
    return healthy
}
