import Library
import SwiftUI

/// Settings > Downloads.
struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    var body: some View {
        @Bindable var downloads = model.downloads
        Form {
            Section {
                Picker("Quality", selection: $downloads.settings.quality) {
                    Text("Original").tag(DownloadSettings.Quality.original)
                    Text("AAC").tag(DownloadSettings.Quality.aac).disabled(!ServerFormats.shared.allows("aac"))
                    Text("MP3").tag(DownloadSettings.Quality.mp3).disabled(!ServerFormats.shared.allows("mp3"))
                }
                if downloads.settings.quality != .original {
                    Picker("Bit rate", selection: $downloads.settings.maxBitRate) {
                        ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
            } footer: {
                Text("Original keeps the files as they are on the server. AAC and MP3 are converted by the server and take less space. A change applies to new downloads." + ServerFormats.shared.note)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Storage limit", selection: $downloads.settings.storageLimitGB) {
                    Text("No limit").tag(0.0)
                    ForEach([1.0, 2, 5, 10, 20, 50, 100], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                }
                LabeledContent("Used", value: "\(formatBytes(downloads.usedBytes)) · \(formatSongs(downloads.entries.values.count { $0.state == .done }))")
                HStack {
                    #if os(macOS)
                    Button("Show in Finder") { reveal() }.disabled(downloads.manager == nil)
                    #endif
                    Spacer()
                    Button("Remove All Downloads…", role: .destructive) { confirmClear = true }
                        .disabled(downloads.entries.isEmpty)
                }
            } footer: {
                Text("When the limit is reached, new downloads wait. Your downloads are never deleted on their own; smart downloads have their own sizes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SmartDownloadSettings()
            PlaybackCacheSettings()
        }
        .formStyle(.grouped)
        .settingsPageSize(width: 520, height: 680)
        .task { await ServerFormats.shared.probe(model.client) }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmClear) {
            Button("Remove All", role: .destructive) { model.removeAllDownloads() }
        } message: {
            Text("\(formatBytes(downloads.usedBytes)) of music are deleted from this Mac. The songs stay in your library.")
        }
    }

    #if os(macOS)
    private func reveal() {
        guard let folder = model.downloads.manager?.filesDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
    #endif
}
