import AppKit
import CoreTransferable
import Foundation
import Integration
import Subsonic

/// Share links: a public server link when the server makes them, else a `musicsync://` link.
extension SystemServices {
    /// `getShares` fails on servers without shares; link sharing stays hidden then.
    func checkShares() {
        guard let client = app.client, let store = app.store else { return }
        Task {
            let supported = (try? await client.getShares()) != nil
            if store === app.store { sharesSupported = supported }
        }
    }

    /// The public link of the item, made on first use; the deep link when the server has no shares.
    /// `downloadable` makes a separate link whose page lets people download the files.
    func link(for target: ShareTarget, downloadable: Bool = false) async throws -> URL {
        let key = target.id + (downloadable ? "#download" : "")
        if let known = shareLinks[key] { return known }
        guard sharesSupported, let client = app.client else { return target.deepLink }
        let store = app.store
        guard let share = try await client.createShare(ids: [target.id], description: target.label, downloadable: downloadable ? true : nil),
              let url = URL(string: share.url) else { return target.deepLink }
        if store === app.store { shareLinks[key] = url }
        return url
    }

    /// The shared text. A failed share request falls back to the deep link.
    func shareText(_ target: ShareTarget) async -> String {
        target.text(link: try? await link(for: target))
    }

    func copyLink(_ target: ShareTarget, downloadable: Bool = false) {
        Task {
            do {
                let url = try await link(for: target, downloadable: downloadable)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } catch { app.report(error) }
        }
    }

    func shares() async throws -> [Share] {
        try await app.client?.getShares() ?? []
    }

    func delete(_ share: Share) async throws {
        try await app.client?.deleteShare(id: share.id)
        shareLinks = shareLinks.filter { $0.value.absoluteString != share.url }
    }
}

/// What `ShareLink` hands to a sharing service. The link is made only when a service is picked.
struct SharedItem: Transferable {
    let target: ShareTarget
    let services: SystemServices

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { (item: SharedItem) in
            Data(await item.services.shareText(item.target).utf8)
        }
    }
}
