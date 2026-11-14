import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run unbundled via `swift run`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MusicSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MusicSync") {
            RootView().environment(model)
        }
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .help) {
                Button("Getting Started") { model.showGuide = true }
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { model.searchFocusRequest += 1 }
                    .keyboardShortcut("f")
            }
            CommandMenu("Playback") {
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.toggle() }
                    .keyboardShortcut("p")  // Space is handled by `SpaceKeyMonitor`, so it still works in text fields.
                Button("Next") { model.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { model.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Toggle("Shuffle", isOn: Binding(get: { model.player.shuffle }, set: { model.player.setShuffle($0) }))
                Picker("Repeat", selection: Binding(get: { model.player.repeatMode }, set: { model.player.repeatMode = $0 })) {
                    Text("Off").tag(RepeatMode.off)
                    Text("All").tag(RepeatMode.all)
                    Text("One").tag(RepeatMode.one)
                }
                Divider()
                Button(model.showNowPlaying ? "Hide Now Playing" : "Show Now Playing") { model.showNowPlaying.toggle() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.player.current == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh Library") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                Button("Sync Library Now") { model.syncLibraryNow() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.library == nil || model.isMirrorRunning)
            }
            CommandMenu("Device") {
                // HOOK: `DeviceModel.startSync` is set by the sync feature.
                Button("Sync Now") { model.ipod.startSync?() }
                    .keyboardShortcut("s")
                    .disabled(model.ipod.current == nil || model.ipod.startSync == nil)
                Divider()
                Button("Eject") { Task { await model.eject() } }
                    .keyboardShortcut("e")
                    .disabled(model.ipod.current == nil || model.ipod.isEjecting || model.ipod.isSyncing)
                Button("Reload Device") { model.ipod.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.ipod.current == nil)
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}
