import Integration
import SwiftUI

/// "Share" (the system share menu, with the cover in its preview) and "Copy Link", for item menus.
struct ShareMenuItems: View {
    @Environment(AppModel.self) private var model
    let target: ShareTarget

    var body: some View {
        let cover = target.coverArt.flatMap { model.covers?.cached(id: $0, size: 600) ?? model.covers?.cached(id: $0, size: 400) }
        let preview = SharePreview(target.label, image: cover.map(Image.init(nsImage:)) ?? Image(systemName: "music.note"))
        ShareLink(item: SharedItem(target: target, services: model.system), preview: preview) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button("Copy Link", systemImage: "link") { model.system.copyLink(target) }
        if model.system.sharesSupported {
            Button("Copy Download Link", systemImage: "arrow.down.circle") { model.system.copyLink(target, downloadable: true) }
        }
    }
}
