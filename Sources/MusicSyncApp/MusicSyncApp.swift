#if os(macOS)
import AppKit
#endif
import Support
import SwiftUI

#if os(macOS)  // the iPad delegate is in iPad/MusicSync/AppDelegate.swift
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run unbundled via `swift run`.
        NSApp.setActivationPolicy(.regular)
        if Shot.output == nil { NSApp.activate(ignoringOtherApps: true) }
        Shot.start(model)
        if let file = HangWatchdog.logFile {
            let model = model
            // The page and the case name of the open route, e.g. "albums album", and the search text.
            HangWatchdog.start(file: file) {
                MainActor.assumeIsolated { "\(model.selection.map { "\($0)" } ?? "-") \(model.path.last.map { Mirror(reflecting: $0).children.first?.label ?? "\($0)" } ?? "") \(model.searchText)" }
            }
        }
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
#endif

@main
struct MusicSyncApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(MenuBarPlayer.shownKey, store: .app) private var showsMenuBarItem = true
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup("MusicSync", id: MainWindow.id) {
            RootView().modifier(SystemEvents())
                #if os(iOS)
                .modifier(PadWindow())
                #endif
                .environment(model)
                .onDisappear { model.covers?.purge() }
        }
        .commands {
            SidebarCommands()
            #if os(macOS)
            MiniPlayerCommands()
            #else
            SettingsCommands()
            #endif
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") { model.playlistPrompt = .create(songIds: []) }
                    .keyboardShortcut("n")
                    .disabled(model.client == nil)
                Button("New Smart Playlist…") { model.smartPlaylists.create() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.library == nil)
            }
            #if os(macOS)  // the guide is about the iPod
            CommandGroup(replacing: .help) {
                Button("Getting Started") { model.showGuide = true }
            }
            #endif
            CommandGroup(after: .textEditing) {
                Button("Search") { model.searchFocusRequest += 1 }
                    #if os(macOS)
                    .keyboardShortcut("f")  // on iPad ⌘F is Edit > Find, see AppDelegate.find(_:)
                    #endif
            }
            CommandMenu("Playback") {
                Button(model.player.isPlaying ? "Pause" : "Play") { model.player.toggle() }
                    .keyboardShortcut("p")  // Space is handled by `SpaceKeyMonitor`, so it still works in text fields.
                Button("Next") { model.player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { model.player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Increase Volume") { model.player.volume = min(model.player.volume + 0.1, 1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Decrease Volume") { model.player.volume = max(model.player.volume - 0.1, 0) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
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
            #if os(macOS)
            CommandGroup(before: .windowList) { EqualizerMenuItem(); VisualizerMenuItem() }
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
            #else
            CommandGroup(before: .windowArrangement) { EqualizerMenuItem(); VisualizerMenuItem() }
            #endif
        }

        #if os(macOS)
        Window("MiniPlayer", id: MiniPlayer.id) {
            MiniPlayerView().environment(model).tint(Color.musicAccent)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 300, height: 300)

        Window("Equalizer", id: EqualizerView.windowID) {
            EqualizerView().environment(model).tint(Color.musicAccent)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()  // `EqualizerMenuItem` has the shortcut

        Window("Visualizer", id: VisualizerView.windowID) {
            VisualizerView().environment(model).tint(Color.musicAccent)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 480)
        .commandsRemoved()  // `VisualizerMenuItem` has the shortcut

        Settings {
            SettingsView().environment(model).tint(Color.musicAccent)
        }

        MenuBarExtra(isInserted: Shot.output == nil ? $showsMenuBarItem : .constant(false)) {  // no item during screenshot runs
            MenuBarPlayer().environment(model)
        } label: {
            MenuBarLabel(player: model.player)
        }
        .menuBarExtraStyle(.window)
        #endif  // iPad shows the Equalizer and Visualizer over the window (`PadWindow`)
    }
}
