import AppKit
import Subsonic
import SwiftUI

/// Settings > Sharing: the public links of this account, to copy or delete. Shown only when the server has shares.
struct SharesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var shares: [Share]?
    @State private var failure: String?
    @State private var toDelete: Share?

    var body: some View {
        Form {
            Section {
                if let shares {
                    if shares.isEmpty { Text("No shared links yet.").foregroundStyle(.secondary) }
                    ForEach(shares) { row($0) }
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
                }
            } header: {
                Text("Shared Links")
            } footer: {
                Text("Anyone with a link can listen to the shared music until the link expires or is deleted.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
        .task(id: model.store.map(ObjectIdentifier.init)) { await load() }
        .confirmationDialog("Delete this link?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
            Button("Delete Link", role: .destructive) { if let toDelete { delete(toDelete) } }
        } message: {
            Text("People who have it can no longer open it. This cannot be undone.")
        }
    }

    private func row(_ share: Share) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(share.description ?? share.entry?.first?.title ?? share.url).lineLimit(1)
                Text(details(share)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(share.url, forType: .string)
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy Link")
            Button("Delete", systemImage: "trash") { toDelete = share }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Delete Link")
        }
    }

    /// "12 songs · 6 visits · expires 13 Nov 2027"
    private func details(_ share: Share) -> String {
        let visits = share.visitCount.map { "\($0) \($0 == 1 ? "visit" : "visits")" }
        let expires = share.expires.flatMap(Self.date).map { "expires " + $0.formatted(date: .abbreviated, time: .omitted) }
        return [share.entry.map { formatSongs($0.count) }, visits, expires].compactMap { $0 }.joined(separator: " · ")
    }

    /// Server dates carry up to nine fraction digits, more than the ISO 8601 parser takes.
    private static func date(_ text: String) -> Date? { try? Date(String(text.prefix(19)) + "Z", strategy: .iso8601) }

    private func load() async {
        do {
            let list = try await model.system.shares()
            shares = list.sorted { ($0.created ?? "") > ($1.created ?? "") }
        } catch where !error.isCancellation {
            failure = error.localizedDescription
        } catch {}
    }

    private func delete(_ share: Share) {
        let before = shares
        shares?.removeAll { $0.id == share.id }
        Task {
            do { try await model.system.delete(share) } catch {
                shares = before
                model.report(error)
            }
        }
    }
}

/// Gray bars in the shape of a share row, while the list loads.
private struct SkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaceholderBlock(width: 180, height: 12)
            PlaceholderBlock(width: 260, height: 9)
        }
        .padding(.vertical, 2)
        .shimmering()
    }
}
