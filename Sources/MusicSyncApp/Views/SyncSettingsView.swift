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
        let presets = model.syncSettings.presets
        let preset = presets.first { $0.id == model.syncSettings.presetID } ?? .stockAAC
        Form {
            Section {
                Picker("Default format", selection: $model.syncSettings.presetID) {
                    ForEach(presets) { Text("\($0.name) (\($0.target == .stock ? "Stock firmware" : "Rockbox"))").tag($0.id) }
                }
                Picker("AAC bitrate", selection: $model.syncSettings.aacBitrate) {
                    ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Opus bitrate", selection: $model.syncSettings.opusBitrate) {
                    ForEach([96, 128, 160, 192, 256], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                LabeledContent("Output", value: preset.codec.summary)
            } header: {
                Text("Format")
            } footer: {
                SettingsFooter("Albums use the default format unless their menu picks another. A new bitrate applies to songs added from now on.")
            }
            Section {
                TextField("ffmpeg path", text: Binding(get: { model.syncSettings.ffmpegPath ?? "" },
                                                       set: { model.syncSettings.ffmpegPath = $0.isEmpty ? nil : $0 }),
                          prompt: Text("Auto-detect"))
                    .autocorrectionDisabled()
                ffmpegStatusView(preset)
                Stepper("Workers: \(model.syncSettings.workers)", value: $model.syncSettings.workers,
                        in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
            } header: {
                Text("Converter")
            } footer: {
                SettingsFooter("ffmpeg converts songs on this Mac; more workers convert more songs at the same time.")
            }
            Section {
                Picker("Sound Check source", selection: $model.syncSettings.soundCheck) {
                    Text("Album gain").tag(SyncSettings.SoundCheckSource.album)
                    Text("Track gain").tag(SyncSettings.SoundCheckSource.track)
                    Text("Off").tag(SyncSettings.SoundCheckSource.off)
                }
                Toggle("Add lyrics to songs", isOn: $model.syncSettings.lyrics)
            } header: {
                Text("Playback on iPod")
            } footer: {
                SettingsFooter("Sound Check uses the ReplayGain tags of the songs. The iPod shows lyrics of new AAC songs from the server.")
            }
            Section {
                Toggle("Always sync whole albums", isOn: $model.syncSettings.fullAlbums)
            } footer: {
                SettingsFooter("Songs from synced playlists bring their full albums.")
            }
            Section {
                Toggle("Convert on the server", isOn: $model.syncSettings.serverConversion)
            } footer: {
                SettingsFooter("Lossless songs come from the server as AAC \(model.syncSettings.aacBitrate)k: about 4× less to download. The server's encoder is a little worse than Apple's, and these songs are not gapless.")
            }
            Section {
                Picker("Keep free on the iPod", selection: $model.syncSettings.keepFreeGB) {
                    ForEach([0.5, 1, 2, 5, 10], id: \.self) { Text("\($0.formatted()) GB").tag($0) }
                }
            } footer: {
                SettingsFooter("A sync that would leave less free space does not start.")
            }
            Section {
                Toggle("Sync when the iPod connects", isOn: $model.syncSettings.autoSync)
                Toggle("Eject after sync", isOn: $model.syncSettings.ejectAfterSync)
                Toggle("Send iPod plays to the server", isOn: $model.syncSettings.sendPlayCounts)
            } header: {
                Text("Automation")
            } footer: {
                SettingsFooter("Plays counted on the iPod always stay on it; when sending is on, the next sync also counts them on the server.")
            }
            Section {
                Picker("Album cover size", selection: $model.syncSettings.rockboxCoverSize) {
                    ForEach([200, 320, 500], id: \.self) { Text("\($0) × \($0)").tag($0) }
                }
            } header: {
                Text("Rockbox")
            } footer: {
                SettingsFooter("Size of the cover.jpg in each album folder; it applies to folders that have no cover yet.")
            }
            DeviceContentSection()
            Section {
                guidFields
            } header: {
                Text("This iPod")
            } footer: {
                SettingsFooter("A new name goes onto the iPod with the next sync. Enter the GUID only when it is not found.")
            }
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
            TextField("Name", text: Binding(get: { model.syncSettings.deviceNames[uuid] ?? model.ipod.snapshot?.name ?? device.volumeName },
                                            set: { model.syncSettings.deviceNames[uuid] = $0.isEmpty ? nil : $0 }))
                .disabled(model.ipod.snapshot?.database == nil)
            LabeledContent("Volume UUID") { Text(uuid).font(.caption.monospaced()).textSelection(.enabled) }
            TextField("Manual GUID", text: manual, prompt: Text("16 hex digits"))
                .autocorrectionDisabled()
            if !manual.wrappedValue.isEmpty, FirewireGuid.parse(manual.wrappedValue) == nil {
                Label("A GUID has exactly 16 hex digits.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            LabeledContent("In use", value: model.ipod.snapshot?.guid ?? "Not found")
                .onChange(of: FirewireGuid.parse(manual.wrappedValue)) { model.ipod.reload() }
        } else {
            Text("Connect an iPod to set its name and GUID.").foregroundStyle(.secondary)
        }
    }
}

extension Preset.Codec {
    var encoder: String {
        switch self {
        case .aac: "aac_at"
        case .flac: "flac"
        case .opus: "libopus"
        case .alac: "alac"
        }
    }

    /// Read-only description of the quality setting.
    var summary: String {
        switch self {
        case .aac(.cvbr(let kbps)): "AAC \(kbps) kbps (constrained VBR)"
        case .aac(.tvbr(let quality)): "AAC VBR, quality \(quality)"
        case .flac(let level): "FLAC, lossless (level \(level))"
        case .opus(let kbps): "Opus \(kbps) kbps"
        case .alac: "Apple Lossless (16-bit)"
        }
    }
}
