import Playback
import SwiftUI

/// Window > Equalizer (⌥⌘E): on/off, presets, preamp and ten bands. Moving a slider turns it on.
struct EqualizerView: View {
    static let windowID = "equalizer"
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        @Bindable var player = model.player
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle("On", isOn: $player.equalizer.isOn)
                Spacer()
                presetMenu
            }
            HStack(alignment: .top, spacing: 4) {
                scale
                EqualizerSlider(value: Binding(get: { player.equalizer.preamp }, set: { player.equalizer.preamp = $0; player.equalizer.isOn = true }),
                                label: "Preamp")
                Divider().frame(height: 150).padding(.horizontal, 8)
                ForEach(EqualizerGains.frequencies.indices, id: \.self) { i in
                    EqualizerSlider(value: Binding(get: { player.equalizer.bands[i] }, set: { player.equalizer.setBand(i, to: $0) }),
                                    label: Self.title(EqualizerGains.frequencies[i]))
                }
            }
        }
        .padding(20)
        .fixedSize()
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") { player.equalizer.savePreset(as: name) }.disabled(!player.equalizer.canSave(as: name))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current bands as a preset.")
        }
    }

    private var presetMenu: some View {
        @Bindable var player = model.player
        let user = player.equalizer.userPresets
        return Menu(player.equalizer.preset ?? "Manual") {
            EqualizerPresetPicker().pickerStyle(.inline)
            Divider()
            Button("Save Preset…") { name = ""; naming = true }
            if let preset = player.equalizer.preset, user.contains(where: { $0.name == preset }) {
                Button("Delete “\(preset)”") { player.equalizer.deletePreset(preset) }
            }
        }
        .fixedSize()
    }

    /// dB marks beside the sliders.
    private var scale: some View {
        VStack(alignment: .trailing) {
            Text("+12 dB")
            Spacer()
            Text("0 dB")
            Spacer()
            Text("−12 dB")
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        .frame(height: 150)
    }

    /// "32", "1K".
    static func title(_ frequency: Double) -> String { frequency >= 1000 ? "\(Int(frequency / 1000))K" : "\(Int(frequency))" }
}

/// A vertical ±12 dB slider with its label below.
private struct EqualizerSlider: View {
    @Binding var value: Double
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let r = EqualizerGains.range, h = geo.size.height
                let y = h * (r.upperBound - value) / (r.upperBound - r.lowerBound)
                ZStack(alignment: .top) {
                    Capsule().fill(.quaternary).frame(width: 4)
                    Capsule().fill(.tint).frame(width: 4, height: h - y).offset(y: y)
                    Circle().fill(.white).shadow(radius: 1).frame(width: 16, height: 16).offset(y: y - 8)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    value = r.upperBound - min(max(g.location.y / h, 0), 1) * (r.upperBound - r.lowerBound)
                })
            }
            .frame(width: 30, height: 150)
            .accessibilityElement()
            .accessibilityLabel(label == "Preamp" ? label : "\(label) Hz")
            .accessibilityValue("\(Int(value.rounded())) dB")
            .accessibilityAdjustableAction { value = min(max(value + ($0 == .increment ? 1 : -1), -12), 12) }
            Text(label).font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
        .frame(width: 34)
    }
}

/// The built-in and the saved presets; picking one sets the bands. Shows Manual when a band was moved by hand.
struct EqualizerPresetPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        let selection = Binding<String?>(get: { player.equalizer.preset }, set: { name in
            if let preset = player.equalizer.presets.first(where: { $0.name == name }) { player.equalizer.apply(preset) }
        })
        Picker("Preset", selection: selection) {
            if player.equalizer.preset == nil { Text("Manual").tag(String?.none) }
            ForEach(EqualizerPreset.builtIn) { Text($0.name).tag(Optional($0.name)) }
            if !player.equalizer.userPresets.isEmpty {
                Divider()
                ForEach(player.equalizer.userPresets) { Text($0.name).tag(Optional($0.name)) }
            }
        }
    }
}

/// Window > Equalizer, ⌥⌘E.
struct EqualizerMenuItem: View {
    private var openWindow = OpenToolWindow()

    var body: some View {
        Button("Equalizer") { openWindow(id: EqualizerView.windowID) }
            .keyboardShortcut("e", modifiers: [.command, .option])
    }
}

/// Settings > Playback: the equalizer switch and preset, and the way to its window.
struct EqualizerSettingsSection: View {
    @Environment(AppModel.self) private var model
    private var openWindow = OpenToolWindow()

    var body: some View {
        @Bindable var player = model.player
        Section {
            Toggle("Equalizer", isOn: $player.equalizer.isOn)
            if player.equalizer.isOn { EqualizerPresetPicker().pickerStyle(.menu) }
            Button("Show Equalizer…") { openWindow(id: EqualizerView.windowID) }
        } footer: {
            Text("Shapes the sound of every song. Window > Equalizer (⌥⌘E) has all bands.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
