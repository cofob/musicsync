import AppKit
import Support
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run unbundled via `swift run`.
        NSApp.setActivationPolicy(.regular)
        if Shot.output == nil { NSApp.activate(ignoringOtherApps: true) }
        Shot.start(model)
        model.system.start()
        model.remote.start()
        // SIGTERM (`kill`, `pkill`) quits like ⌘Q instead of killing the process mid-sync.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()
    }

    /// A running sync stops first, so the iPod database is written before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.ipod.isSyncing else { return .terminateNow }
        model.sync.cancel()
        Task {
            while model.ipod.isSyncing { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockMenu.make(model.player) }
}

@main
struct MusicSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    @AppStorage(MenuBarPlayer.shownKey, store: .app) private var showsMenuBarItem = true

    var body: some Scene {
        WindowGroup("MusicSync", id: MainWindow.id) {
            RootView().modifier(SystemEvents()).environment(model)
        }
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") { model.playlistPrompt = .create(songIds: []) }
                    .keyboardShortcut("n")
                    .disabled(model.client == nil)
            }
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
                Toggle("AutoPlay", isOn: Binding(get: { model.mixes.autoPlay }, set: { model.mixes.autoPlay = $0 }))
                    .disabled(!model.mixes.isAvailable)
                Divider()
                Toggle("Private Session", isOn: Binding(get: { model.player.privateSession }, set: { model.player.privateSession = $0 }))
                SleepTimerPicker(selection: Binding(get: { model.player.sleepTimer }, set: { model.player.sleepTimer = $0 }))
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
                Button("Sync Now") { model.sync.dismissRun(); model.sync.showSheet = true }
                    .keyboardShortcut("s")
                    .disabled(model.ipod.current == nil)
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

        MenuBarExtra(isInserted: Shot.output == nil ? $showsMenuBarItem : .constant(false)) {  // no item during screenshot runs
            MenuBarPlayer().environment(model)
        } label: {
            MenuBarLabel(player: model.player)
        }
        .menuBarExtraStyle(.window)
    }
}
