import Subsonic
import SwiftUI
import Sync

// MARK: Selection controls

/// Small status icon over an album cover, like the download arrow of Apple Music.
struct SyncBadge: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        if let (symbol, help) = info {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .help(help)
        }
    }

    private var info: (String, String)? {
        let sync = model.sync
        guard let status = sync.status(of: album) else { return nil }
        switch status {
        case .none: return nil
        case .synced: return ("checkmark", "On iPod")
        case .partial: return ("circle.lefthalf.filled", "Partly on iPod")
        case .pending: return ("arrow.down", "Waiting to sync")
        case .outdated: return ("exclamationmark", sync.isSelected(album) ? "On iPod in old quality; updated on the next sync" : "On iPod in old quality")
        case .foreign: return ("ipod", sync.isSelected(album) ? "On iPod via iTunes; skipped by sync to avoid a duplicate" : "On iPod via iTunes")
        }
    }
}

/// Round accent toggle for page headers (album, artist, playlist), like the Apple Music download button.
struct SyncButton: View {
    @Environment(AppModel.self) private var model
    let isOn: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        if model.sync.isAvailable {
            Button(isOn ? "Remove from iPod" : "Sync to iPod", systemImage: isOn ? "checkmark" : "arrow.down", action: action)
                .buttonStyle(CircleIconStyle(size: 34))
                .disabled(!isEnabled || model.sync.isRunning)
                .help(isOn ? "Remove from iPod" : "Sync to iPod")
        }
    }
}

/// Album page header accessory.
struct AlbumSyncButton: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        let sync = model.sync
        SyncButton(isOn: sync.isSelected(album), isEnabled: !sync.isSelectedByArtist(album)) { sync.toggle(album) }
        if sync.isSelected(album), sync.status(of: album) == .foreign {
            Label("On iPod via iTunes, not synced", systemImage: "ipod").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// "Sync to iPod" / "Remove from iPod" for menus.
struct SyncMenuItem: View {
    @Environment(AppModel.self) private var model
    let isOn: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        if model.sync.isAvailable {
            Divider()
            Button(isOn ? "Remove from iPod" : "Sync to iPod", systemImage: isOn ? "minus.circle" : "arrow.down.circle", action: action)
                .disabled(!isEnabled || model.sync.isRunning)
        }
    }
}

// MARK: Sidebar

/// Sync status under the device rows; opens the sync sheet.
struct SyncStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        let pending = sync.run?.isFinished != false && sync.preview?.plan.isEmpty == false
        HStack(spacing: 8) {
            Button { sync.showSheet = true } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let run = sync.run, !run.isFinished {
                        ProgressView(value: run.fraction).controlSize(.small).tint(Color.musicAccent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle())
            // Explicit start: opens the preview, where the sync is confirmed.
            if pending {
                Button("Sync…", systemImage: "arrow.trianglehead.2.clockwise") { sync.dismissRun(); sync.showSheet = true }
                    .buttonStyle(.borderedProminent).tint(Color.musicAccent).controlSize(.small)
                    .help("Review and start the sync")
            }
        }
        .padding(.leading, 4)
    }

    private var text: String {
        let sync = model.sync
        if let run = sync.run {
            if run.cancelling && !run.isFinished { return "Stopping…" }
            if run.error != nil { return "Sync failed" }
            if let summary = run.summary { return summary.cancelled ? "Sync stopped" : "Sync complete" }
            return run.progress.map { "Syncing \($0.itemsDone) of \($0.itemsTotal)…" } ?? "Syncing…"
        }
        if sync.previewError != nil { return "Cannot prepare sync" }
        if model.client == nil { return "No server connected" }
        guard let plan = sync.preview?.plan else { return sync.checkingText ?? "Checking…" }
        if plan.isEmpty { return "Up to date" }
        let parts = [(plan.add.count, "to add"), (plan.reencode.count + plan.retag.count, "to update"), (plan.remove.count, "to remove")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Playlists to update" : parts.joined(separator: ", ")
    }
}

// MARK: Sheet

/// Preview, progress and summary of a sync.
struct SyncSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sync = model.sync
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "ipod").font(.system(size: 30)).foregroundStyle(Color.musicAccent)
                VStack(alignment: .leading) {
                    Text(title).font(.title2.bold())
                    Text(model.ipod.snapshot?.name ?? model.ipod.current?.volumeName ?? "iPod").foregroundStyle(.secondary)
                }
            }
            if let run = sync.run {
                if run.isFinished { summary(run) } else { progress(run) }
            } else {
                preview
            }
        }
        .padding(24)
        .frame(width: 480)
        .tint(Color.musicAccent)
        .onDisappear { sync.dismissRun() }
    }

    private var title: String {
        guard let run = model.sync.run else { return "Sync" }
        if run.error != nil { return "Sync Failed" }
        if let summary = run.summary { return summary.cancelled ? "Sync Stopped" : "Sync Complete" }
        return run.cancelling ? "Stopping…" : "Syncing"
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        let sync = model.sync
        if let error = sync.previewError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            buttons { Button("Try Again") { sync.deviceUpdated() } }
        } else if let preview = sync.preview {
            let plan = preview.plan
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Add", count: plan.add.count, bytes: plan.addBytes)
                if plan.filledSongs > 0 { row("From Most Played", count: plan.filledSongs) }
                row("Update", count: plan.reencode.count + plan.retag.count)
                row("Remove", count: plan.remove.count, bytes: plan.freedBytes)
                row("Playlists", count: plan.playlistsToCreate.count + plan.playlistsToUpdate.count,
                    unit: "changes")
                Divider()
                GridRow {
                    Text("Free after sync").foregroundStyle(.secondary)
                    Text(formatBytes(max(0, plan.freeBytes + plan.freedBytes - plan.addBytes))).gridColumnAlignment(.trailing)
                }
            }
            if !plan.fits {
                Label("The selection doesn't fit: free \(formatBytes(plan.addBytes + plan.reserveBytes - plan.freeBytes - plan.freedBytes)) more or select less.",
                      systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if plan.isEmpty {
                Text(preview.hasPlayCounts ? "Your music is up to date. Syncing saves play counts from the iPod and sends scrobbles."
                                           : "Your music is up to date.").foregroundStyle(.secondary)
            }
            if preview.needsGuid {
                VStack(alignment: .leading, spacing: 4) {
                    Label("The FireWire GUID of this iPod is unknown, so its database cannot be signed.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    SettingsLink { Text("Enter it in Settings ▸ Sync") }.buttonStyle(.link)
                }
            }
            if !plan.skippedForeignAlbums.isEmpty {
                DisclosureGroup {
                    Text(plan.skippedForeignAlbums.values.sorted().joined(separator: "\n")).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    let n = plan.skippedForeignAlbums.count
                    Label("\(n) \(n == 1 ? "album is" : "albums are") already on the iPod (added by iTunes) and skipped",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            buttons {
                Button("Sync") { sync.start() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!preview.canRun)
            }
        } else if model.client == nil {
            Text("Connect to a server to sync.").foregroundStyle(.secondary)
            buttons { Button("Sync") {}.buttonStyle(.borderedProminent).disabled(true) }
        } else {
            HStack { ProgressView().controlSize(.small); Text(sync.checkingText ?? "Preparing…").foregroundStyle(.secondary) }
            buttons { Button("Sync") {}.buttonStyle(.borderedProminent).disabled(true) }
        }
    }

    /// Rows with a zero count are left out.
    @ViewBuilder private func row(_ title: String, count: Int, bytes: Int64? = nil, unit: String = "songs") -> some View {
        if count > 0 {
            GridRow {
                Text(title).foregroundStyle(.secondary)
                Text("\(count) \(count == 1 ? String(unit.dropLast()) : unit)").monospacedDigit()
                Text(bytes.map(formatBytes) ?? "").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            }
        }
    }

    // MARK: Progress

    @ViewBuilder private func progress(_ run: SyncModel.Run) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(phaseTitle(run.phase)).font(.headline)
            ProgressView(value: run.fraction).tint(Color.musicAccent)
            // A space keeps the line's height before the first progress event.
            Text(run.progress.map { "\($0.itemsDone) of \($0.itemsTotal) items · \(formatBytes($0.bytesDone)) of \(formatBytes($0.bytesTotal))" } ?? " ")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        // Always 6 rows tall, so the sheet does not change size while files start and finish.
        let active = Array(run.items.filter(\.stage.isActive).prefix(6))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<6, id: \.self) { i in
                HStack {
                    Text(i < active.count ? active[i].title : " ").lineLimit(1)
                    Spacer()
                    Text(i < active.count ? active[i].stage.title : "").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
            }
        }
        failures(run.items.compactMap { if case .failed(let why) = $0.stage { ($0.title, why) } else { nil } })
        if run.cancelling {
            Text("MusicSync finishes the files in work and writes the iPod database, so nothing is left half-done.")
                .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            Button("Stop Sync", role: .destructive) { model.sync.cancel() }.disabled(run.cancelling)
            Spacer()
            Button("Hide") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Summary

    @ViewBuilder private func summary(_ run: SyncModel.Run) -> some View {
        if let error = run.error {
            Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
        if let s = run.summary {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Added", count: s.added)
                row("Updated", count: s.reencoded + s.retagged)
                row("Removed", count: s.removed)
                row("Failed", count: s.failures.count)
                row("Scrobbles sent", count: s.scrobblesSent, unit: "plays")
                row("Scrobbles queued", count: s.scrobblesPending, unit: "plays")
            }
            if s.added + s.reencoded + s.retagged + s.removed + s.failures.count + s.scrobblesSent + s.scrobblesPending == 0 {
                Text(s.cancelled ? "Nothing was changed." : "Play counts are saved. No songs changed.").foregroundStyle(.secondary)
            }
            failures(s.failures.map { ($0.title, $0.message) })
        }
        ForEach(run.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
        HStack {
            if model.ipod.current != nil {
                Button("Eject", systemImage: "eject.fill") { dismiss(); Task { await model.eject() } }
            }
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func failures(_ list: [(String, String)]) -> some View {
        if !list.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(failure.0).lineLimit(1)
                            Text(failure.1).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
    }

    private func buttons(@ViewBuilder primary: () -> some View) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            primary()
        }
    }

    private func phaseTitle(_ phase: SyncPhase) -> String {
        switch phase {
        case .preparing: "Preparing…"
        case .backingUp: "Backing up the iPod database…"
        case .readingDevice: "Reading the iPod…"
        case .removing: "Removing songs…"
        case .transferring: "Copying songs…"
        case .artwork: "Writing artwork…"
        case .playlists: "Updating playlists…"
        case .writing: "Writing the iPod database…"
        case .scrobbling: "Sending scrobbles…"
        case .ejecting: "Ejecting…"
        }
    }
}

private extension ItemStage {
    var isActive: Bool {
        switch self {
        case .downloading, .transcoding, .copying: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .queued: "Waiting"
        case .downloading(let done, let total):
            total > 0 ? "Downloading \(formatBytes(done)) of \(formatBytes(total))" : "Downloading \(formatBytes(done))"
        case .transcoding(let f): "Converting \(Int(f * 100))%"
        case .copying: "Copying"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

// MARK: Cover hover

/// Apple Music cover hover: Play at the bottom left, sync to iPod at the bottom right.
private struct CoverHoverActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let play: (() -> Void)?
    let isSynced: Bool
    var syncEnabled = true
    let toggleSync: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if hovering {
                    HStack {
                        if let play { Button("Play", systemImage: "play.fill", action: play) }
                        Spacer()
                        if model.sync.isAvailable {
                            Button(isSynced ? "Remove from iPod" : "Sync to iPod",
                                   systemImage: isSynced ? "checkmark" : "arrow.down", action: toggleSync)
                                .disabled(!syncEnabled || model.sync.isRunning)
                                .help(isSynced ? "Remove from iPod" : "Sync to iPod")
                        }
                    }
                    .buttonStyle(HoverCircleStyle())
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

/// Dark glass circle with a white glyph, readable on any cover.
private struct HoverCircleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .animation(.press) { $0.background(.black.opacity(configuration.isPressed ? 0.7 : 0.5), in: Circle()) }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
    }
}

extension View {
    func albumHoverActions(_ album: Album) -> some View {
        modifier(AlbumHoverActions(album: album))
    }

    func playlistHoverActions(_ playlist: Playlist) -> some View {
        modifier(PlaylistHoverActions(playlist: playlist))
    }
}

private struct AlbumHoverActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let album: Album
    func body(content: Content) -> some View {
        let sync = model.sync
        content.modifier(CoverHoverActions(play: { model.play(album) }, isSynced: sync.isSelected(album),
                                           syncEnabled: !sync.isSelectedByArtist(album)) { sync.toggle(album) })
    }
}

private struct PlaylistHoverActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    func body(content: Content) -> some View {
        let sync = model.sync
        content.modifier(CoverHoverActions(play: { model.play(playlist) }, isSynced: sync.isPlaylistSelected(playlist.id)) {
            sync.togglePlaylist(playlist.id)
        })
    }
}
