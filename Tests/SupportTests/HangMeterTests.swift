import Foundation
import Testing
@testable import Support

@Test func meterKeepsTheLongestStallOfALap() async throws {
    let queue = DispatchQueue(label: "metered")
    let meter = HangMeter(queue: queue)
    defer { meter.stop() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(meter.lap() < 0.1)
    queue.async { Thread.sleep(forTimeInterval: 0.3) }
    try await Task.sleep(for: .milliseconds(500))
    let stall = meter.lap()
    #expect(stall >= 0.25 && stall < 0.5)
    try await Task.sleep(for: .milliseconds(100))
    #expect(meter.lap() < 0.1)  // the next lap starts fresh
}
