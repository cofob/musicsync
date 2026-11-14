import SwiftUI

struct DeviceOverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ipod = model.ipod
        if let s = ipod.snapshot {
            Form {
                header(s)
                if let error = s.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                Section("Device") {
                    LabeledContent("Model", value: s.modelName ?? "Unknown")
                    LabeledContent("Firmware", value: s.firmware ?? "Unknown")
                    LabeledContent("FireWire GUID") { guid(s) }
                    if s.rockbox {
                        Label("Rockbox is installed on this iPod. The iPod database shown here is used by the stock firmware only.",
                              systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
                if let capacity = s.capacity {
                    Section("Storage") {
                        CapacityBar(snapshot: s, capacity: capacity, projectedDelta: ipod.projectedSyncDelta)
                    }
                }
                Section("Contents") {
                    LabeledContent("Songs", value: s.tracks.count.formatted())
                    LabeledContent("Albums", value: s.albums.count.formatted())
                    LabeledContent("Playlists", value: s.playlists.count.formatted())
                    LabeledContent("Orphaned files") {
                        HStack {
                            if let orphans = s.orphans {
                                Text(orphans.count == 0 ? "None" : "\(orphans.count) · \(formatBytes(orphans.bytes))")
                                // HOOK: `DeviceModel.cleanOrphans` is provided by the sync feature.
                                Button("Clean Up…") { Task { await ipod.cleanOrphans?() } }
                                    .disabled(ipod.cleanOrphans == nil || orphans.count == 0)
                            } else if ipod.isScanningOrphans {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Check") { ipod.scanOrphans() }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Overview")
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ s: DeviceSnapshot) -> some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "ipod").font(.system(size: 44)).foregroundStyle(Color.musicAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.title.bold())
                    Text(s.device.mountURL.path).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.ipod.isLoading { ProgressView().controlSize(.small) }
                Button("Reload", systemImage: "arrow.clockwise") { model.ipod.reload() }
                Button("Eject", systemImage: "eject.fill") { Task { await model.eject() } }
                    .disabled(model.ipod.isEjecting || model.ipod.isSyncing)
                // HOOK: `DeviceModel.startSync` is provided by the sync feature.
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") { model.ipod.startSync?() }
                    .buttonStyle(.borderedProminent).tint(Color.musicAccent)
                    .disabled(model.ipod.startSync == nil)
            }
            .buttonBorderShape(.capsule).controlSize(.large)
        }
    }

    @ViewBuilder private func guid(_ s: DeviceSnapshot) -> some View {
        if let guid = s.guid {
            Text(guid).monospaced().textSelection(.enabled)
        } else {
            HStack {
                Label("Not found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                SettingsLink { Text("Set in Settings > Sync") }.buttonStyle(.link)
            }
        }
    }
}

/// Stacked bar: music on the iPod, other files, free space. Pending sync changes are drawn when known.
private struct CapacityBar: View {
    private struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let color: Color
    }

    let snapshot: DeviceSnapshot
    let capacity: DeviceSnapshot.Capacity
    /// Slot for the sync estimate: bytes added (positive) or removed (negative) by the planned sync.
    let projectedDelta: Int64?

    private var segments: [Segment] {
        let used = max(0, capacity.total - capacity.available)
        var music = min(snapshot.musicBytes, used)
        let other = used - music
        var free = capacity.available
        var toAdd: Int64 = 0, toRemove: Int64 = 0
        if let delta = projectedDelta {
            if delta > 0 { toAdd = min(delta, free); free -= toAdd } else { toRemove = min(-delta, music); music -= toRemove }
        }
        return [Segment(id: "Music", bytes: music, color: .blue),
                Segment(id: "To remove", bytes: toRemove, color: .red.opacity(0.5)),
                Segment(id: "To add", bytes: toAdd, color: Color.musicAccent.opacity(0.6)),
                Segment(id: "Other", bytes: other, color: .gray),
                Segment(id: "Free", bytes: free, color: .secondary.opacity(0.2))]
    }

    var body: some View {
        let segments = segments
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        segment.color.frame(width: geo.size.width * CGFloat(segment.bytes) / CGFloat(max(capacity.total, 1)))
                    }
                }
            }
            .frame(height: 14).clipShape(Capsule())
            HStack(spacing: 16) {
                ForEach(segments.filter { $0.bytes > 0 || ["Music", "Other", "Free"].contains($0.id) }) { segment in
                    Label {
                        Text("\(segment.id) \(formatBytes(segment.bytes))")
                    } icon: {
                        Circle().fill(segment.color).frame(width: 9, height: 9)
                    }
                }
                Spacer()
                Text("\(formatBytes(capacity.total)) total").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}
