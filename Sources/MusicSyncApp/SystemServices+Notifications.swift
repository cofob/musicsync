import SwiftUI
import Support
import UserNotifications

/// A banner with the cover when the song changes while the app is in the background (General settings; off by default).
extension SystemServices {
    /// `UNUserNotificationCenter` needs an app bundle (not `swift run`); demo and screenshot runs never post.
    static var mayNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" && !Paths.isDemo && Shot.output == nil }

    func requestNotifications() {
        guard Self.mayNotify else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
    }

    func trackChanged() {
        guard notifiesTrackChange, Self.mayNotify, !appIsActive, let item = app.player.current else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = byline(item.artist, item.album)
        let covers = app.covers, cover = item.coverArt, id = item.id
        Task {
            if let cover, let image = await covers?.image(id: cover, size: 600), let file = await Self.writeJPEG(image) {
                // The system moves the file into its own store.
                content.attachments = (try? UNNotificationAttachment(identifier: "cover", url: file)).map { [$0] } ?? []
            }
            guard app.player.current?.id == id else { return }  // skipped meanwhile
            // One identifier: each banner replaces the last one.
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nowPlaying", content: content, trigger: nil))
        }
    }

    private nonisolated static func writeJPEG(_ image: NSImage) async -> URL? {
        await Task.detached(priority: .utility) {
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("musicsync-cover-\(UUID().uuidString).jpg")
            return (try? jpeg.write(to: url)) != nil ? url : nil
        }.value
    }
}
