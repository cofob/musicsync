import Library
import SwiftUI

/// Library mirror status in the bottom-left corner of the sidebar. Fixed height, so state changes never move the list.
/// A click opens details and controls.
struct LibraryStatusView: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        let status = model.mirrorStatus
        Button { showDetails.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(status.state))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(status.state.isFailed ? Color.orange : Color.musicAccent)
                    .symbolEffect(.rotate, isActive: status.state == .running)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.state == .running ? LibraryStatusText.phaseName(status.phase)
                                                  : LibraryStatusText.title(status, lastSync: model.lastLibrarySync))
                        .font(.callout).lineLimit(1)
                    if status.state == .running {
                        HStack(spacing: 6) {
                            ProgressView(value: status.fraction ?? 0).progressViewStyle(.linear).controlSize(.mini).tint(Color.musicAccent)
                            Text(LibraryStatusText.count(status)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize()
                        }
                    } else {
                        LibraryStatusText.subtitle(status, lastSync: model.lastLibrarySync)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 34)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glass(in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .help("Library sync")
        .popover(isPresented: $showDetails, arrowEdge: .top) { LibraryStatusDetails().environment(model) }
    }

    private func symbol(_ state: MirrorState) -> String {
        switch state {
        case .running: "arrow.triangle.2.circlepath"
        case .idle: "checkmark.circle"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.triangle"
        case .disabled: "icloud.slash"
        }
    }
}

/// A pressed card shrinks a little with an animation; `.plain` dims it at once instead.
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Texts shared by the sidebar status and its popover.
enum LibraryStatusText {
    static func phaseName(_ phase: MirrorPhase?) -> String {
        switch phase {
        case .scan?, nil: "Checking Library"
        case .artists?: "Syncing Artists"
        case .albums?: "Syncing Albums"
        case .tracks?: "Syncing Songs"
        case .playlists?: "Syncing Playlists"
        case .favorites?: "Syncing Favorites"
        case .covers?: "Syncing Covers"
        case .lyrics?: "Syncing Lyrics"
        }
    }

    /// "1 200 of 3 850", or the done count while the total is unknown.
    static func count(_ status: MirrorStatus) -> String {
        let done = status.done.formatted()
        return status.total.map { "\(done) of \($0.formatted())" } ?? done
    }

    static func title(_ status: MirrorStatus, lastSync: Date?) -> String {
        switch status.state {
        case .running: return "\(phaseName(status.phase)) · \(count(status))"
        case .idle: return (status.lastSuccess ?? lastSync) == nil ? "Library not synced yet" : "Library up to date"
        case .paused: return "Library sync paused"
        case .failed: return "Library sync failed"
        case .disabled: return "Library sync off"
        }
    }

    /// "Updated 5 min ago", refreshed every 30 s; the failure reason when failed.
    @ViewBuilder static func subtitle(_ status: MirrorStatus, lastSync: Date?) -> some View {
        if case .failed(let message) = status.state {
            Text(message)
        } else if let date = status.lastSuccess ?? lastSync {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("Updated \(date.formatted(.relative(presentation: .named)))")
            }
        } else {
            Text(status.state == .disabled ? "Turn it on in Settings" : "Waiting for the server")
        }
    }
}

/// Popover: state, progress, warnings and the controls.
private struct LibraryStatusDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.mirrorStatus
        VStack(alignment: .leading, spacing: 10) {
            Text("Library Sync").font(.headline)
            Text(LibraryStatusText.title(status, lastSync: model.lastLibrarySync)).font(.callout)
            if status.state == .running {
                if let fraction = status.fraction {
                    ProgressView(value: fraction).tint(Color.musicAccent)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Color.musicAccent)
                }
            }
            LibraryStatusText.subtitle(status, lastSync: model.lastLibrarySync)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if status.warnings > 0 {
                Label("\(status.warnings) \(status.warnings == 1 ? "item" : "items") skipped", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .help(status.lastWarning ?? "")
            }
            Text(model.usesLocalLibrary ? "Pages load from the local library." : "Pages load from the server until the first sync ends.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(status.state.isFailed ? "Retry" : "Sync Now") { model.syncLibraryNow() }
                    .disabled(status.state == .running || model.library == nil)
                if status.state == .running || status.state == .paused {
                    Button(status.state == .paused ? "Resume" : "Pause") { model.toggleMirrorPause() }
                }
                Spacer()
                SettingsLink { Text("Settings…") }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: 300)
    }
}

extension MirrorState {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// Settings > Library.
struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var diskSize: Int64?
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Sync library in the background", isOn: $model.mirrorSettings.enabled)
                Picker("Check for changes", selection: $model.mirrorSettings.intervalMinutes) {
                    ForEach([15, 30, 60, 180, 360], id: \.self) { minutes in
                        Text(minutes < 60 ? "Every \(minutes) minutes" : minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours").tag(minutes)
                    }
                }
                .disabled(!model.mirrorSettings.enabled)
                Toggle("Download lyrics", isOn: $model.mirrorSettings.includeLyrics)
                Toggle("Download cover thumbnails", isOn: $model.mirrorSettings.includeCovers)
            } footer: {
                Text("A local copy of the server library makes pages and search open at once. Sync runs in the background and never blocks the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status", value: LibraryStatusText.title(model.mirrorStatus, lastSync: model.lastLibrarySync))
                LabeledContent("Last sync") {
                    if let date = model.mirrorStatus.lastSuccess ?? model.lastLibrarySync {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never")
                    }
                }
                LabeledContent("Local library", value: diskSize.map(formatBytes) ?? "—")
                HStack {
                    Button("Sync Now") { model.syncLibraryNow() }
                        .disabled(model.isMirrorRunning || model.library == nil)
                    Spacer()
                    Button("Reset Local Library…", role: .destructive) { confirmReset = true }
                        .disabled(model.library == nil)
                }
            }
            HomeAndListeningSections()
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.mirrorStatus.state) { diskSize = await model.libraryDiskSize() }
        .confirmationDialog("Reset the local library?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                Task {
                    await model.resetLibrary()
                    diskSize = await model.libraryDiskSize()
                }
            }
        } message: {
            Text("The local copy of the library is deleted and downloaded again. Music on the server and on the iPod is not touched.")
        }
    }
}
