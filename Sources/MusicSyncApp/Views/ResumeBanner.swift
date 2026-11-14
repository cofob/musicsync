import SwiftUI

/// "Continue from <device>": a small bar over the player when another device saved a newer queue on the server.
struct ResumeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let offer = model.serverQueue.offer {
            HStack(spacing: 12) {
                CoverImage(id: offer.song.coverArt, size: 100, cornerRadius: 5).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Continue from \(offer.device)").font(.callout.weight(.semibold)).lineLimit(1)
                    Text([offer.song.title, offer.song.artistName].compactMap { $0 }.joined(separator: " — "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Resume", systemImage: "play.fill") { model.serverQueue.resume() }
                    .buttonStyle(FilledCapsuleStyle())
                Button("Dismiss", systemImage: "xmark") { model.serverQueue.dismiss() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
            .frame(maxWidth: 460)
            .glass(in: Capsule())
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Settings > Playback: the server play queue, for servers that keep one.
struct QueueSyncSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var queue = model.serverQueue
        Section {
            Toggle("Sync queue with server", isOn: $queue.enabled)
        } footer: {
            Text("Saves the queue on the server, so you can continue on another device. When another device played later, MusicSync offers to continue from there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
