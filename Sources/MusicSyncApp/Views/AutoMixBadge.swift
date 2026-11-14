import SwiftUI

/// Shown while AutoMix mixes the current song into the next one, as in Apple Music. For the dark Now Playing view.
struct AutoMixBadge: View {
    var body: some View {
        Label("AutoMix", systemImage: "wand.and.stars")
            .font(.caption.weight(.semibold)).textCase(.uppercase)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(.white.opacity(0.75))
            .background(.white.opacity(0.15), in: Capsule())
            .transition(.opacity)
    }
}
