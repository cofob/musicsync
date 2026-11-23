import SwiftUI

/// The first screen on iPad, until a server is saved: what the app does, and the server form.
struct PadOnboarding: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Color.musicAccent.gradient, in: RoundedRectangle(cornerRadius: 22))
                .padding(.bottom, 8)
            Text("Welcome to MusicSync").font(.largeTitle.bold())
            Text("MusicSync plays music from your Navidrome server. Enter the server address, user name and password. The library is kept on this iPad, so browsing and search are fast, also offline.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            ServerSettingsView()
                .frame(maxWidth: 560)
                .scrollDisabled(true)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .tint(Color.musicAccent)
    }
}
