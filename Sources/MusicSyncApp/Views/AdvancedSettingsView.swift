import Preferences
import SwiftUI

/// Settings > Advanced.
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var cacheSize: Int64?
    @State private var exporting = false
    @State private var confirmReset = false

    var body: some View {
        @Bindable var prefs = AppPreferences.shared
        Form {
            Section {
                Picker("Request timeout", selection: $prefs.advanced.requestTimeout) {
                    ForEach(AdvancedSettings.timeouts, id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("Network")
            } footer: {
                SettingsFooter("How long a server request may wait for data. A new value applies after Save on the Server page or at the next launch.")
            }
            Section {
                Picker("Limit", selection: $prefs.advanced.coverCacheMB) {
                    ForEach(AdvancedSettings.coverCacheSizes, id: \.self) { mb in
                        Text(mb == 0 ? "No Limit" : formatBytes(Int64(mb) * 1_000_000)).tag(mb)
                    }
                }
                HStack {
                    LabeledContent("In use", value: cacheSize.map(formatBytes) ?? "—")
                    Button("Clear") { Task { await model.clearCoverCache(); await measure() } }
                }
            } header: {
                Text("Cover Cache")
            } footer: {
                SettingsFooter("Covers load again from the server when they are needed. The oldest ones go first when the cache is full.")
            }
            Section {
                HStack {
                    #if os(macOS)
                    Button("Export Diagnostics…") { export() }.disabled(exporting)
                    #else
                    ShareLink("Export Diagnostics…", item: DiagnosticsFile(server: model.config?.baseURL),
                              preview: SharePreview("MusicSync Diagnostics.zip"))
                    #endif
                    if exporting { ProgressView().controlSize(.small) }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                SettingsFooter("Saves a zip with the app log since launch, the settings and versions. Passwords and tokens are removed.")
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
            } footer: {
                SettingsFooter("The server, paired remotes, iPod selections and the library are kept.")
            }
        }
        .formStyle(.grouped)
        .settingsPageSize(width: 480)
        .task { await measure() }
        .onChange(of: prefs.advanced.coverCacheMB) {
            model.trimCoverCache()
            Task { try? await Task.sleep(for: .milliseconds(500)); await measure() }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetAllSettings() }
        } message: {
            Text("All options return to their defaults. Shortcuts, Remote and Downloads options do so at the next launch.")
        }
    }

    private func measure() async { cacheSize = await model.coverCacheSize() }

    #if os(macOS)
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MusicSync Diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        let server = model.config?.baseURL
        Task {
            do { try await Task.detached(priority: .userInitiated) { try Diagnostics.export(to: url, server: server) }.value } catch { model.report(error) }
            exporting = false
        }
    }
    #endif
}
