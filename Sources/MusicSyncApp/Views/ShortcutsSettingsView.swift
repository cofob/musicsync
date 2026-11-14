import AppKit
import Carbon.HIToolbox
import Integration
import SwiftUI

/// Settings > Shortcuts: global keyboard shortcuts with recorders. A combo taken from another action moves;
/// one held by another app is marked.
struct ShortcutsSettingsView: View {
    @Environment(AppModel.self) private var model
    /// The action whose recorder waits for keys.
    @State var recording: HotKeyAction?
    /// The action that lost its combo to the last recorded one.
    @State private var moved: HotKeyAction?
    @State private var monitor: Any?

    var body: some View {
        @Bindable var system = model.system
        Form {
            Section {
                Toggle("Use global keyboard shortcuts", isOn: $system.hotKeys.enabled)
            } footer: {
                Text("They work while MusicSync is in the background. Use ⌘, ⌥ or ⌃ in each one, or a function key.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { row($0) }
            } footer: {
                if let moved {
                    Text("The shortcut was removed from “\(moved.title)”.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(!system.hotKeys.enabled)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: recording, initial: true) { updateMonitor() }
        .onDisappear { recording = nil; updateMonitor() }
    }

    private func row(_ action: HotKeyAction) -> some View {
        let combo = model.system.hotKeys.combos[action]
        return LabeledContent(action.title) {
            HStack(spacing: 6) {
                if model.system.takenHotKeys.contains(action) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help("Another app uses this shortcut.")
                }
                Button { recording = recording == action ? nil : action } label: {
                    Text(recording == action ? "Type Shortcut…" : combo?.display ?? "Record Shortcut")
                        .foregroundStyle(recording == action || combo == nil ? .secondary : .primary)
                        .frame(minWidth: 120)
                }
                .overlay { if recording == action { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.musicAccent, lineWidth: 2) } }
                Button("Clear", systemImage: "xmark.circle.fill") { assign(nil, to: action) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                    .opacity(combo == nil ? 0 : 1).disabled(combo == nil)
            }
        }
    }

    private func assign(_ combo: KeyCombo?, to action: HotKeyAction) {
        moved = model.system.hotKeys.assign(combo, to: action)
        recording = nil
    }

    /// While recording, keys go to the recorder and the global shortcuts are off, so the old combo can be typed again.
    private func updateMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let action = recording else { return model.system.applyHotKeys() }
        model.system.hotKeyCenter?.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape where flags.isEmpty: recording = nil
            case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty: assign(nil, to: action)
            default:
                let combo = KeyCombo(keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers)
                if combo.isValid { assign(combo, to: action) } else { NSSound.beep() }
            }
            return nil
        }
    }
}
