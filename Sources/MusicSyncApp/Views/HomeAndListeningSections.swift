import Preferences
import SwiftUI

/// Settings > Library: the Home sections and what happens with plays.
struct HomeAndListeningSections: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        @Bindable var prefs = AppPreferences.shared
        let order = prefs.home.order
        Section {
            ForEach(order, id: \.self) { shelf in
                HStack {
                    Toggle(shelf.title, isOn: Binding(get: { prefs.home.shows(shelf) }, set: { prefs.home.setShown(shelf, $0) }))
                    Spacer()
                    Button("Move Up", systemImage: "chevron.up") { withAnimation { prefs.home.move(shelf, by: -1) } }
                        .disabled(shelf == order.first)
                    Button("Move Down", systemImage: "chevron.down") { withAnimation { prefs.home.move(shelf, by: 1) } }
                        .disabled(shelf == order.last)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
        } header: {
            Text("Home")
        } footer: {
            SettingsFooter("Turn sections of the Home page on or off and set their order. Made for You needs the local library.")
        }
        Section {
            Toggle("Send plays to the server", isOn: $prefs.listening.scrobble)
            Picker("Play counts for stats and mixes", selection: $prefs.listening.playsSource) {
                Text("Listening History on This Mac").tag(ListeningSettings.PlaysSource.history)
                Text("Server Play Counts Only").tag(ListeningSettings.PlaysSource.server)
            }
            HStack {
                Spacer()
                Button("Clear Listening History…", role: .destructive) { confirmClear = true }.disabled(model.library == nil)
            }
        } header: {
            Text("Listening")
        } footer: {
            SettingsFooter("Sent plays count on the server and on Last.fm if it is linked. The history on this Mac feeds Your Stats and the mixes.")
        }
        .confirmationDialog("Clear the listening history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { Task { await model.clearHistory() } }
        } message: {
            Text("The plays recorded on this Mac are deleted, so Your Stats and the mixes start over. Play counts on the server stay.")
        }
        Section {
            Toggle("Find missing lyrics on LRCLIB", isOn: $prefs.listening.lrclibLyrics)
                .onChange(of: prefs.listening.lrclibLyrics) { model.lyricsCache = [:] }
        } header: {
            Text("Lyrics")
        } footer: {
            SettingsFooter("When the server has no lyrics for the song in Now Playing, its title, artist, album and length are sent to lrclib.net.")
        }
    }
}
