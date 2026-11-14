import Foundation
import Playback
import Testing

@Suite struct ResumePointTests {
    @Test func savesOnlyLongItemsInTheMiddle() {
        #expect(ResumePoint.action(elapsed: 120, duration: 300) == .none)  // a song
        #expect(ResumePoint.action(elapsed: 120, duration: 600) == .none)
        #expect(ResumePoint.action(elapsed: 120.5, duration: 3600) == .save(120_500))
        #expect(ResumePoint.action(elapsed: 3, duration: 3600) == .none)  // just started
        #expect(ResumePoint.action(elapsed: 3580, duration: 3600) == .delete)  // finished
        #expect(ResumePoint.action(elapsed: 3700, duration: 3600) == .delete)
        #expect(ResumePoint.action(elapsed: .nan, duration: 3600) == .none)
        #expect(ResumePoint.action(elapsed: .infinity, duration: 3600) == .none)
    }

    @Test func resumesInsideTheItem() {
        #expect(ResumePoint.resume(position: 61_500, duration: 3600) == 61.5)
        #expect(ResumePoint.resume(position: 61_500, duration: 300) == nil)
        #expect(ResumePoint.resume(position: 5000, duration: 3600) == nil)
        #expect(ResumePoint.resume(position: 3_590_000, duration: 3600) == nil)
        #expect(ResumePoint.resume(position: -1, duration: 3600) == nil)
        #expect(ResumePoint.resume(position: .max, duration: 3600) == nil)
        #expect(ResumePoint.progress(position: 1_800_000, duration: 3600) == 0.5)
        #expect(ResumePoint.progress(position: 0, duration: 3600) == nil)
    }
}
