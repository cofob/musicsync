import Foundation
import OSLog
import Support

/// Settings > Advanced > Export Diagnostics: a zip with the app log since launch, the settings and versions.
/// Every file goes through `Redact`, so passwords and tokens stay on the Mac.
enum Diagnostics {
    /// Settings saved as JSON that go into the zip. Remote pairings and the server password are not among them.
    static let settingsKeys = ["syncSettings", "libraryMirrorSettings", "playbackSettings", "equalizerSettings", "downloadSettings",
                               "appearanceSettings", "homeSettings", "listeningSettings", "advancedSettings"]

    /// Blocking; call off the main actor.
    static func export(to zip: URL, server: URL?) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("MusicSync Diagnostics")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try write(info(server: server), "info.txt", in: folder)
        try write(settings(), "settings.json", in: folder)
        try write(log(), "log.txt", in: folder)
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func write(_ text: String, _ name: String, in folder: URL) throws {
        try Redact.secrets(in: text).write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func info(server: URL?) -> String {
        let bundle = Bundle.main.infoDictionary ?? [:]
        return """
            MusicSync \(bundle["CFBundleShortVersionString"] as? String ?? "development build") (\(bundle["CFBundleVersion"] as? String ?? "-"))
            macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            Server: \(server?.host ?? "none")
            Demo: \(Paths.isDemo)
            """
    }

    private static func settings() -> String {
        var all: [String: Any] = [:]
        for key in settingsKeys {
            if let data = UserDefaults.app.data(forKey: key), let value = try? JSONSerialization.jsonObject(with: data) { all[key] = value }
        }
        let data = (try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// This run's messages of the app's subsystem.
    private static func log() -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: Date().addingTimeInterval(-86400)),
                                                  matching: NSPredicate(format: "subsystem BEGINSWITH %@", "MusicSync")) else {
            return "The log is not available."
        }
        let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
            "\($0.date.formatted(.iso8601)) [\($0.category)] \($0.composedMessage)"
        }
        return lines.isEmpty ? "No messages." : lines.joined(separator: "\n")
    }
}
