import SwiftUI

/// Rounded square that shows `image`, or a symbol placeholder.
struct CoverFrame: View {
    let image: NSImage?
    var cornerRadius: CGFloat = 8
    var symbol = "music.note"

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    GeometryReader { geo in
                        Image(systemName: symbol).font(.system(size: geo.size.width * 0.4)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Square cover art. `size` is the requested edge in pixels. Shows the mirror's local thumbnail at once,
/// then swaps in the full server image without clearing in between (no flash).
struct CoverImage: View {
    @Environment(AppModel.self) private var model
    let id: String?
    var size = 300
    var cornerRadius: CGFloat = 8
    var symbol = "music.note"
    @State private var image: NSImage?
    /// Cover id `image` belongs to; a reused view never shows the previous cover.
    @State private var imageID: String?

    var body: some View {
        let shown = imageID == id ? image : id.flatMap { model.covers?.cached(id: $0, size: size) }
        CoverFrame(image: shown, cornerRadius: cornerRadius, symbol: symbol)
            .task(id: id) {
                guard let id, let covers = model.covers else { image = nil; imageID = id; return }
                if let hit = covers.cached(id: id, size: size) { image = hit; imageID = id; return }
                if imageID != id { image = nil; imageID = id }
                // Big contexts reuse a full cover downloaded before; small ones (≤ 96 px) keep the thumbnail.
                if size > 96, let local = await covers.local(id: id, size: size), !Task.isCancelled {
                    image = local.image
                    if local.exact { return }
                } else if let small = await model.smallCover(id), !Task.isCancelled {
                    image = small
                    if size <= 96 { return }
                }
                if let full = await covers.image(id: id, size: size), !Task.isCancelled { image = full }
            }
            // Long lists keep their offscreen views; the image goes, the cache brings it back at once.
            .onDisappear { image = nil; imageID = nil }
    }
}
