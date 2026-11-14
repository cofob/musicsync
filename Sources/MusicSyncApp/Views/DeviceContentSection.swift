import SwiftUI
import Sync

/// Settings > Sync: what the current iPod gets besides the chosen albums, artists and playlists. Saved per iPod.
struct DeviceContentSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sync = model.sync
        Section {
            if sync.isAvailable {
                Toggle("Favorite songs", isOn: binding(\.favorites))
                Toggle("Fill free space with most played albums", isOn: binding(\.fillMostPlayed))
                if let plan = sync.preview?.plan {
                    LabeledContent("Next sync", value: summary(plan))
                } else if sync.isPlanning {
                    LabeledContent("Next sync") { ProgressView().controlSize(.small) }
                }
            } else {
                Text("Connect an iPod to choose what it gets.").foregroundStyle(.secondary)
            }
        } header: {
            Text("On This iPod")
        } footer: {
            SettingsFooter("Favorites also make a Favorites playlist. Most played albums are added while they fit and the space to keep free stays free. Sync never removes songs by itself.")
        }
    }

    private func binding(_ key: WritableKeyPath<Selection, Bool>) -> Binding<Bool> {
        Binding(get: { model.sync.selection[keyPath: key] }, set: { on in model.sync.update { $0[keyPath: key] = on } })
    }

    /// "12 songs to add (48 MB), 2 to update".
    private func summary(_ plan: SyncPlan) -> String {
        if plan.isEmpty { return "Up to date" }
        let add = plan.add.isEmpty ? nil : "\(plan.add.count) to add (\(formatBytes(plan.addBytes)))"
        let update = plan.reencode.count + plan.retag.count
        return [add, update > 0 ? "\(update) to update" : nil, plan.remove.isEmpty ? nil : "\(plan.remove.count) to remove"]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
