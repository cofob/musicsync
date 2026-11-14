import Foundation
import Testing
@testable import Support

@Test func watchdogLogsOnlyStalls() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("hangs-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: file) }
    let queue = DispatchQueue(label: "watched")
    let thread = HangWatchdog.start(file: file, queue: queue, threshold: 0.25, context: { "page=albums" })
    defer { thread.cancel() }
    try await Task.sleep(for: .milliseconds(300))
    #expect((try? String(contentsOf: file, encoding: .utf8)) == "")
    queue.async { Thread.sleep(forTimeInterval: 0.5) }
    try await Task.sleep(for: .milliseconds(700))
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1)
    let ms = lines.first.flatMap { Int($0.split(separator: " ")[1]) } ?? 0
    #expect(ms >= 250)  // the ping may start a little after the stall
    #expect(lines.first?.hasSuffix("ms page=albums") == true)
}
