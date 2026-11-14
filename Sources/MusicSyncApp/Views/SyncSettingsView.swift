import Device
import SwiftUI
import Sync
import Transcode

/// "Sync" tab of the Settings window.
struct SyncSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var ffmpegStatus = FFmpegStatus.checking

    private enum FFmpegStatus {
        case checking, missing
        /// `encoder`: nil while unknown, else whether the selected preset's encoder exists.
        case found(path: String, encoder: Bool?)
    }

    var body: some View {
        @Bindable var model = model
        let preset = Preset.builtIns.first { $0.id == model.syncSettings.presetID } ?? .stockAAC
        Form {
            Section("Encoding") {
                Picker("Default preset", selection: $model.syncSettings.presetID) {
                    ForEach(Preset.builtIns) { Text("\($0.name) (\($0.target == .stock ? "Stock firmware" : "Rockbox"))").tag($0.id) }
                }
                LabeledContent("Bitrate", value: preset.codec.summary)
                TextField("ffmpeg path", text: Binding(get: { model.syncSettings.ffmpegPath ?? "" },
                                                       set: { model.syncSettings.ffmpegPath = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Auto-detect"))
                    .autocorrectionDisabled()
                ffmpegStatusView(preset)
                Stepper("Workers: \(model.syncSettings.workers)", value: $model.syncSettings.workers,
                        in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
            }
            Section("Playback on iPod") {
                Picker("Sound Check source", selection: $model.syncSettings.soundCheck) {
                    Text("Album gain").tag(SyncSettings.SoundCheckSource.album)
                    Text("Track gain").tag(SyncSettings.SoundCheckSource.track)
                    Text("Off").tag(SyncSettings.SoundCheckSource.off)
                }
                Toggle("Eject after sync", isOn: $model.syncSettings.ejectAfterSync)
            }
            Section {
                Toggle("Always sync whole albums", isOn: $model.syncSettings.fullAlbums)
            } footer: {
                Text("Songs from synced playlists bring their full albums.").font(.caption).foregroundStyle(.secondary)
            }
            Section("FireWire GUID") { guidFields }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: "\(model.syncSettings.ffmpegPath ?? "")|\(preset.id)") { await checkFFmpeg(preset) }
    }

    // MARK: ffmpeg

    @ViewBuilder private func ffmpegStatusView(_ preset: Preset) -> some View {
        switch ffmpegStatus {
        case .checking:
            ProgressView().controlSize(.small)
        case .missing:
            Label("ffmpeg not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .found(let path, let encoder):
            VStack(alignment: .leading, spacing: 4) {
                Label(path, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                switch encoder {
                case nil: EmptyView()
                case true?: Label("Encoder \(preset.codec.encoder) available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case false?: Label("Encoder \(preset.codec.encoder) missing in this ffmpeg", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .font(.callout)
        }
    }

    private func checkFFmpeg(_ preset: Preset) async {
        ffmpegStatus = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        guard let ffmpeg = FFmpeg.locate(explicitPath: model.syncSettings.ffmpegPath) else { return ffmpegStatus = .missing }
        ffmpegStatus = .found(path: ffmpeg.ffmpeg.path, encoder: nil)
        let supported = (try? await ffmpeg.supports(preset)) ?? false
        guard !Task.isCancelled else { return }
        ffmpegStatus = .found(path: ffmpeg.ffmpeg.path, encoder: supported)
    }

    // MARK: GUID

    @ViewBuilder private var guidFields: some View {
        @Bindable var model = model
        if let device = model.ipod.current, let uuid = device.volumeUUID {
            let manual = Binding(get: { model.syncSettings.manualGuids[uuid] ?? "" }, set: {
                let text = $0.trimmingCharacters(in: .whitespaces)
                model.syncSettings.manualGuids[uuid] = text.isEmpty ? nil : text
            })
            LabeledContent("Device", value: model.ipod.snapshot?.name ?? device.volumeName)
            LabeledContent("Volume UUID") { Text(uuid).font(.caption.monospaced()).textSelection(.enabled) }
            TextField("Manual GUID", text: manual, prompt: Text("16 hex digits"))
                .autocorrectionDisabled()
            if !manual.wrappedValue.isEmpty, FirewireGuid.parse(manual.wrappedValue) == nil {
                Label("A GUID has exactly 16 hex digits.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            LabeledContent("In use", value: model.ipod.snapshot?.guid ?? "Not found")
                .onChange(of: manual.wrappedValue.isEmpty ? nil : FirewireGuid.parse(manual.wrappedValue) != nil) { model.ipod.reload() }
        } else {
            Text("Connect an iPod to set its GUID.").foregroundStyle(.secondary)
        }
    }
}

extension Preset.Codec {
    var encoder: String {
        switch self {
        case .aac: "aac_at"
        case .flac: "flac"
        case .opus: "libopus"
        }
    }

    /// Read-only description of the quality setting.
    var summary: String {
        switch self {
        case .aac(.cvbr(let kbps)): "AAC \(kbps) kbps (constrained VBR)"
        case .aac(.tvbr(let quality)): "AAC VBR, quality \(quality)"
        case .flac(let level): "FLAC, lossless (level \(level))"
        case .opus(let kbps): "Opus \(kbps) kbps"
        }
    }
}
