import Observation
import Playback
import Testing

@MainActor @Observable private final class Counter {
    var watched = 0
    var other = 0
}

@MainActor @Suite struct NextChangeTests {
    @Test func returnsAfterAChangeOfWhatItReads() async {
        let counter = Counter()
        var done = false
        let wait = Task { await nextChange { _ = counter.watched }; done = true }
        try? await Task.sleep(for: .milliseconds(50))  // the task starts waiting
        counter.other += 1
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!done)
        counter.watched += 1
        await wait.value
        #expect(done)
    }
}
