import SwiftUI

/// The Settings sheet of one window.
@MainActor @Observable final class SettingsSheet {
    var isShown = false
}

extension EnvironmentValues {
    @Entry var settingsSheet: SettingsSheet?
}

extension FocusedValues {
    @Entry var settingsSheet: SettingsSheet?
}

/// iPad has no Settings scene: Settings opens as a sheet over the window. Keeps the Mac's `SettingsLink` calls as they are.
struct SettingsLink<Label: View>: View {
    @Environment(\.settingsSheet) private var sheet
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { sheet?.isShown = true } label: { label() }
    }
}

/// Each iPad window: the Settings sheet, the Equalizer and Visualizer over it, and Space for Play/Pause on a hardware keyboard.
struct PadWindow: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var sheet = SettingsSheet()
    @State private var tools = ToolSheet()

    func body(content: Content) -> some View {
        @Bindable var sheet = sheet
        content
            .environment(\.settingsSheet, sheet)
            .focusedSceneValue(\.settingsSheet, sheet)
            .environment(\.toolSheet, tools)
            .focusedSceneValue(\.toolSheet, tools)
            // One presenter at a time: over Settings while it is open, else over the window.
            .modifier(ToolPresenter(tools: tools, isActive: !sheet.isShown))
            .sheet(isPresented: $sheet.isShown) {
                SettingsView().environment(model).environment(\.toolSheet, tools).presentationSizing(.page)
                    .modifier(ToolPresenter(tools: tools, isActive: true))
            }
            .onKeyPress(.space) {
                guard !model.player.queue.isEmpty else { return .ignored }
                model.player.toggle()
                return .handled
            }
    }
}

/// The Equalizer as a sheet, the Visualizer full screen with a close button.
private struct ToolPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let tools: ToolSheet
    let isActive: Bool

    func body(content: Content) -> some View {
        let id = isActive ? tools.id : nil  // read here, so a new id shows the sheet
        content
            .sheet(isPresented: shown(EqualizerView.windowID, id)) {
                EqualizerView().environment(model).tint(Color.musicAccent)
                    .padding(.top, 8).presentationSizing(.fitted).presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: shown(VisualizerView.windowID, id)) {
                VisualizerView().environment(model).tint(Color.musicAccent)
                    .overlay(alignment: .topLeading) {
                        Button("Close", systemImage: "xmark") { tools.id = nil }
                            .labelStyle(.iconOnly).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).glass(in: Circle(), interactive: true)
                            .padding(16).keyboardShortcut(.cancelAction)
                    }
            }
    }

    private func shown(_ tool: String, _ id: String?) -> Binding<Bool> {
        Binding(get: { id == tool }, set: { if !$0, tools.id == tool { tools.id = nil } })
    }
}

/// ⌘, opens Settings in the front window.
struct SettingsCommands: Commands {
    @FocusedValue(\.settingsSheet) private var sheet

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { sheet?.isShown = true }
                .keyboardShortcut(",")
                .disabled(sheet == nil)
        }
    }
}
