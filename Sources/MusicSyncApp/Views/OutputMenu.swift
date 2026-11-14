import SwiftUI

/// Output choice beside AirPlay: this Mac or the server's own output (jukebox). Hidden when the server has none.
struct OutputButton: View {
    @Environment(AppModel.self) private var model
    var tint: Color = .primary
    @State private var showsList = false

    var body: some View {
        let jukebox = model.jukebox
        if jukebox.isAvailable {
            Button("Output", systemImage: jukebox.isActive ? "hifispeaker.fill" : "hifispeaker") { showsList.toggle() }
                .labelStyle(.iconOnly)
                .foregroundStyle(jukebox.isActive ? Color.musicAccent : tint)
                .help(jukebox.isActive ? "Playing on Server" : "Play on This Mac or on the Server")
                .accessibilityValue(jukebox.isActive ? "Server" : "This Mac")
                .popover(isPresented: $showsList, arrowEdge: .top) { OutputList().environment(model) }
        }
    }
}

/// "Playing on Server" while the jukebox plays, so it is clear that the sound is not on this Mac.
struct PlayingOnServerLabel: View {
    var body: some View {
        Label("Playing on Server", systemImage: "hifispeaker.fill").lineLimit(1)
    }
}

/// The outputs, with a checkmark on the one that plays; a pick moves playback there at once.
struct OutputList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let jukebox = model.jukebox
        VStack(alignment: .leading, spacing: 2) {
            Text("Play On").font(.headline).padding(.horizontal, 8).padding(.bottom, 4)
            OutputRow(title: "This Mac", detail: "Computer", symbol: "laptopcomputer", isOn: !jukebox.isActive) {
                Task { await jukebox.deactivate() }
            }
            OutputRow(title: "Server", detail: jukebox.serverName, symbol: "hifispeaker.fill", isOn: jukebox.isActive) {
                Task { await jukebox.activate() }
            }
        }
        .padding(10)
        .frame(width: 260)
    }
}

/// One output: its symbol in a circle (accent when it plays), name, detail and a checkmark; gray when chosen or hovered.
private struct OutputRow: View {
    let title: String
    let detail: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(isOn ? Color.musicAccent : Color.primary.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isOn { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.musicAccent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(isOn ? 0.08 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
