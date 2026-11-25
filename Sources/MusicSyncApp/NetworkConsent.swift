import Preferences
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Asks the user before the app connects to a host other than their server (`ExternalService`), and keeps the answer
/// in `AppPreferences.access` (Settings > Advanced > External Services).
@MainActor enum NetworkConsent {
    /// One popup per service at a time.
    private static var asking: [ExternalService: Task<Bool, Never>] = [:]

    /// A saved Allow; never asks (background work).
    static func allowed(_ service: ExternalService) -> Bool { AppPreferences.shared.access[service] == true }

    /// The saved answer, else asks once (automatic work).
    static func allows(_ service: ExternalService, hosts: [String] = []) async -> Bool {
        if let answer = AppPreferences.shared.access[service] { return answer }
        return await request(service, hosts: hosts)
    }

    /// Asks unless Allow is saved (a user action, so that it does not fail silently after a Deny).
    static func request(_ service: ExternalService, hosts: [String] = []) async -> Bool {
        if allowed(service) { return true }
        let task = asking[service] ?? Task { await ask(service, hosts: hosts) }
        asking[service] = task
        let answer = await task.value
        asking[service] = nil
        AppPreferences.shared.access[service] = answer
        return answer
    }

    private static func ask(_ service: ExternalService, hosts: [String]) async -> Bool {
        let all = (service.hosts + hosts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let title = "Allow MusicSync to connect to \(service.title)?"
        let text = "\(service.purpose)\n\n\(service.reason)\n\nHosts: \(all.joined(separator: ", "))\n\n"
            + "MusicSync sends nothing else. You can change this in Settings > Advanced."
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
        #else
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return false }
        while let next = top.presentedViewController { top = next }
        return await withCheckedContinuation { done in
            let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don’t Allow", style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Allow", style: .default) { _ in done.resume(returning: true) })
            top.present(alert, animated: true)
        }
        #endif
    }
}
