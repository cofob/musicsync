import AppKit
import CoreImage.CIFilterBuiltins
import Remote
import SwiftUI

/// Settings > Remote: turn on the web remote, pair devices with a code or QR code, revoke them,
/// and copy example URLs for Shortcuts.
struct RemoteSettingsView: View {
    @Environment(AppModel.self) private var model
    /// A token made for Shortcuts; shown until the tab closes.
    @State private var newToken: String?

    var body: some View {
        @Bindable var remote = model.remote
        Form {
            Section {
                Toggle("Allow control from iPhone, iPad and Apple Watch", isOn: $remote.isEnabled)
                TextField("Port", value: $remote.port, format: .number.grouping(.never))
                if remote.isEnabled {
                    LabeledContent("Address") { CopyText(text: remote.address) }
                }
                if let failure = remote.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Open the address in Safari on a device on the same network. Add it to the Home Screen for a full-screen remote.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if remote.isEnabled {
                pairing
                devices
                shortcuts
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Color.musicAccent)
        .onDisappear { model.remote.closePairing(); newToken = nil }
    }

    @ViewBuilder private var pairing: some View {
        let remote = model.remote
        Section("Pair a Device") {
            if let code = remote.pairingCode, let ends = remote.pairingEnds {
                HStack(spacing: 18) {
                    if let qr = Self.qrCode(remote.pairingLink) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 132, height: 132)
                            .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(code.prefix(3) + " " + code.suffix(3)).font(.system(size: 34, weight: .semibold, design: .monospaced))
                        Text("Scan the code with the camera, or open the address and type this code.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(ends.timeIntervalSince(context.date)))
                            Text(left > 0 ? "Expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Expired")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Button("Cancel") { remote.closePairing() }
                    }
                }
                .padding(.vertical, 4)
            } else {
                Button("Pair a Device…") { remote.openPairing() }
            }
        }
    }

    @ViewBuilder private var devices: some View {
        let remote = model.remote
        Section {
            if remote.devices.isEmpty { Text("No paired devices.").foregroundStyle(.secondary) }
            ForEach(remote.devices) { device in
                HStack {
                    Image(systemName: Self.symbol(device.name)).foregroundStyle(Color.musicAccent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text("Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke") { remote.revoke(device) }
                }
            }
        } header: {
            Text("Paired Devices")
        } footer: {
            Text("A revoked device must pair again.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shortcuts: some View {
        let base = model.remote.address
        Section {
            if let newToken {
                LabeledContent("Token") { CopyText(text: newToken) }
            } else {
                Button("New Token for Shortcuts") { newToken = model.remote.newToken(name: "Shortcuts") }
            }
            LabeledContent("Play or pause") { CopyText(text: base + "/api/command/toggle", shown: "/api/command/toggle") }
            LabeledContent("Next song") { CopyText(text: base + "/api/command/next", shown: "/api/command/next") }
            LabeledContent("Volume") { CopyText(text: base + "/api/command/volume?value=0.5", shown: "/api/command/volume?value=0.5") }
            LabeledContent("Now playing") { CopyText(text: base + "/api/state", shown: "/api/state") }
        } header: {
            Text("Shortcuts on iPhone")
        } footer: {
            Text("Use “Get Contents of URL” with method POST (GET for Now playing) and the header Authorization: Bearer <token>. The token is shown once. The musicsync://command/… links keep working on this Mac.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private static func symbol(_ name: String) -> String {
        switch name {
        case "iPhone": "iphone"
        case "iPad": "ipad"
        case "Apple Watch": "applewatch"
        case "Shortcuts": "square.2.layers.3d"
        default: "globe"
        }
    }

    private static let context = CIContext()

    /// Black-on-white QR code of `text`, one pixel per module.
    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: output.extent.size)
    }
}

/// Monospaced text with a copy button; `shown` is a shorter form to show.
private struct CopyText: View {
    let text: String
    var shown: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(shown ?? text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy")
        }
    }
}
