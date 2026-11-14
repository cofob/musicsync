import SwiftUI

/// Getting-started pages: what the app does, then the steps before the first sync.
struct GuideView: View {
    static let shownKey = "guideShown"
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let text: String
        var steps: [String] = []
    }

    private let pages = [
        Page(symbol: "ipod", title: "Welcome to MusicSync",
             text: "MusicSync plays music from your Navidrome server and puts it on your iPod classic. It converts songs to a format the iPod plays and adds covers, playlists and Sound Check."),
        Page(symbol: "server.rack", title: "Connect Your Server",
             text: "Open Settings and enter the server address, user name and password. MusicSync keeps a copy of the library on this Mac, so browsing and search are fast, also offline.",
             steps: ["Choose MusicSync > Settings (⌘,).", "Enter the server details and click Save."]),
        Page(symbol: "checkmark.circle", title: "Choose What to Sync",
             text: "Move the pointer over an album or playlist cover and click the sync button. Or use Sync to iPod in the context menu. Albums with a check mark go to the iPod.",
             steps: ["To always copy whole albums of playlist songs, turn on “Always sync whole albums” in Settings > Sync.",
                     "Songs that iTunes or Finder put on the iPod stay there. MusicSync shows them but does not change them."]),
        Page(symbol: "exclamationmark.triangle", title: "Turn Off Sync in Finder",
             text: "Finder can replace the iPod library when it syncs. Do these steps one time, before the first sync with MusicSync:",
             steps: ["Connect the iPod and select it in the Finder sidebar.",
                     "On the General tab, clear “Automatically sync when this iPod is connected”.",
                     "Select “Manually manage music, movies, and TV shows”.",
                     "Select “Enable disk use”, then click Apply.",
                     "Do not click Sync in Finder after this."]),
        Page(symbol: "arrow.trianglehead.2.clockwise", title: "Sync and Eject",
             text: "Select the iPod in the sidebar. Click Sync to see what changes, then start. Click Eject before you disconnect the iPod.",
             steps: ["The first sync of many albums can take a long time: the iPod disk is slow.",
                     "Reopen this guide from Help > Getting Started."]),
    ]

    var body: some View {
        let current = pages[page]
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: current.symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.musicAccent)
                    .frame(height: 56)
                Text(current.title).font(.title2.bold())
                Text(current.text)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !current.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(current.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(step).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .id(page)
            .transition(.opacity)

            HStack {
                Button("Skip") { close() }.opacity(page == pages.count - 1 ? 0 : 1)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle().fill(index == page ? Color.primary : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                Button(page == pages.count - 1 ? "Done" : "Continue") {
                    if page == pages.count - 1 { close() } else { page += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520, height: 500)
        .animation(.easeInOut(duration: 0.2), value: page)
    }

    private func close() {
        UserDefaults.app.set(true, forKey: Self.shownKey)
        dismiss()
    }
}
