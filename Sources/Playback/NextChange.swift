import Observation

/// Returns after an observable property that `read` reads changes, so an idle loop sleeps until there is work.
@MainActor public func nextChange(of read: () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        withObservationTracking(read) { done.resume() }
    }
}
