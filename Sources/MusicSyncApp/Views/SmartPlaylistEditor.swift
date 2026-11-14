import Library
import SwiftUI

/// The smart playlist sheet, as in Apple Music: rule rows with − and + (and … for a nested group), a limit,
/// live updating, and the count and length of what the rules match while they change.
struct SmartPlaylistEditor: View {
    typealias P = SmartPlaylist
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: P
    let isNew: Bool
    @State private var preview: P.Matches?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SmartPlaylistIcon(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $draft.name).textFieldStyle(.plain).font(.title3.bold())
                    Text(summary).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                matchHeader($draft.rules.match, "the following rules:")
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(draft.rules.items) { item in
                            switch item {
                            case .rule(let rule): row(rule, nested: false)
                            case .group(let group): groupBox(group)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 120, maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            limitRow
            Toggle("Live updating", isOn: $draft.liveUpdating)
                .help("Off: the songs stay as they match when you save.")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "OK") { save() }.keyboardShortcut(.defaultAction).disabled(isSaving)
            }
        }
        .toggleStyle(.checkbox)
        .padding(20)
        .frame(width: 720)
        .tint(Color.musicAccent)
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await model.smartPlaylists.preview(draft)
            if !Task.isCancelled { preview = found }
        }
    }

    private var summary: String {
        guard let preview else { return "Counting…" }
        var parts = [formatSongs(preview.ids.count)]
        if preview.duration > 0 { parts.append(formatTotal(preview.duration)) }
        if preview.size > 0 { parts.append(formatBytes(preview.size)) }
        return parts.joined(separator: ", ")
    }

    private func matchHeader(_ match: Binding<P.Match>, _ tail: String) -> some View {
        HStack(spacing: 6) {
            Text("Match")
            Picker("Match", selection: match) {
                Text("all").tag(P.Match.all)
                Text("any").tag(P.Match.any)
            }
            .labelsHidden().fixedSize()
            Text("of \(tail)")
        }
    }

    private func groupBox(_ group: P.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                matchHeader(Binding(get: { draft.rules[group: group.id]?.match ?? .all }, set: { draft.rules[group: group.id]?.match = $0 }),
                            "these rules:")
                Spacer()
                buttons(remove: { draft.rules.remove(group.id) }, add: { draft.rules.insert(.rule(newRule), after: group.id) }, addGroup: nil)
            }
            ForEach(group.items) { item in
                if case .rule(let rule) = item { row(rule, nested: true) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func row(_ rule: P.Rule, nested: Bool) -> some View {
        let binding = Binding(get: { draft.rules[rule: rule.id] ?? rule }, set: { draft.rules[rule: rule.id] = $0 })
        return HStack(spacing: 8) {
            SmartRuleFields(rule: binding)
            buttons(remove: draft.rules.items.count > 1 || nested ? { draft.rules.remove(rule.id) } : nil,
                    add: { draft.rules.insert(.rule(newRule), after: rule.id) },
                    addGroup: nested ? nil : { draft.rules.insert(.group(P.Group(match: .any, items: [.rule(newRule)])), after: rule.id) })
        }
    }

    /// − and +, and … for a nested group; `remove` nil disables −.
    private func buttons(remove: (() -> Void)?, add: @escaping () -> Void, addGroup: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            Button("Remove Rule", systemImage: "minus") { remove?() }.disabled(remove == nil)
            Button("Add Rule", systemImage: "plus", action: add)
            if let addGroup { Button("Add Nested Rules", systemImage: "ellipsis", action: addGroup) }
        }
        .buttonStyle(CircleIconStyle(size: 22))
    }

    private var newRule: P.Rule { P.Rule(field: .artist, op: .contains) }

    private var limitRow: some View {
        HStack(spacing: 6) {
            Toggle("Limit to", isOn: $draft.limit.isOn)
            TextField("Amount", value: $draft.limit.amount, format: .number.grouping(.never)).frame(width: 60).labelsHidden()
            Picker("Unit", selection: $draft.limit.unit) {
                ForEach(P.Limit.Unit.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            Text("selected by")
            Picker("Order", selection: $draft.limit.by) {
                ForEach(P.Order.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        .disabled(isSaving)
    }

    private func save() {
        isSaving = true
        Task {
            await model.smartPlaylists.save(draft)
            dismiss()
        }
    }
}

/// Field, operator and value of one rule.
private struct SmartRuleFields: View {
    typealias P = SmartPlaylist
    @Binding var rule: P.Rule

    var body: some View {
        HStack(spacing: 6) {
            Picker("Field", selection: Binding(get: { rule.field }, set: { rule.setField($0) })) {
                ForEach(P.Field.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize().frame(width: 130, alignment: .leading)
            Picker("Operator", selection: $rule.op) {
                ForEach(rule.field.kind.operators, id: \.self) { Text($0.title(for: rule.field.kind)).tag($0) }
            }
            .labelsHidden().fixedSize().frame(width: 160, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var value: some View {
        switch rule.field.kind {
        case .text:
            TextField("Value", text: $rule.text).labelsHidden()
        case .number:
            number($rule.number)
            if rule.op == .inRange { Text("to"); number($rule.number2) }
            if let unit = rule.field.unit { Text(unit).foregroundStyle(.secondary) }
        case .date where rule.op == .inLast || rule.op == .notInLast:
            number($rule.number)
            Text("days").foregroundStyle(.secondary)
        case .date:
            date($rule.number)
            if rule.op == .inRange { Text("to"); date($rule.number2) }
        case .flag:
            EmptyView()
        }
    }

    private func number(_ value: Binding<Double>) -> some View {
        TextField("Value", value: value, format: .number.grouping(.never)).labelsHidden().frame(width: 70)
    }

    private func date(_ value: Binding<Double>) -> some View {
        DatePicker("Date", selection: Binding(get: { Date(timeIntervalSince1970: value.wrappedValue) }, set: { value.wrappedValue = $0.timeIntervalSince1970 }),
                   displayedComponents: .date)
            .labelsHidden().datePickerStyle(.field).fixedSize()
    }
}

/// The smart playlist symbol: a gear on gray, as Apple Music draws it.
struct SmartPlaylistIcon: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Color.musicAccent)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.16))
    }
}

extension SmartPlaylist.Field {
    var title: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .genre: "Genre"
        case .format: "Format"
        case .year: "Year"
        case .duration: "Time"
        case .bitRate: "Bit Rate"
        case .playCount: "Plays"
        case .rating: "Rating"
        case .dateAdded: "Date Added"
        case .lastPlayed: "Last Played"
        case .favorite: "Favorite"
        case .downloaded: "Downloaded"
        case .compilation: "Compilation"
        }
    }

    var unit: String? {
        switch self {
        case .duration: "seconds"
        case .bitRate: "kbps"
        case .rating: "stars"
        default: nil
        }
    }
}

extension SmartPlaylist.Operator {
    func title(for kind: SmartPlaylist.Kind) -> String {
        switch self {
        case .contains: "contains"
        case .notContains: "does not contain"
        case .is: "is"
        case .isNot: "is not"
        case .startsWith: "begins with"
        case .endsWith: "ends with"
        case .greater: kind == .date ? "is after" : "is greater than"
        case .less: kind == .date ? "is before" : "is less than"
        case .inRange: "is in the range"
        case .inLast: "is in the last"
        case .notInLast: "is not in the last"
        case .isTrue: "is true"
        case .isFalse: "is false"
        }
    }
}

extension SmartPlaylist.Limit.Unit {
    var title: String {
        switch self {
        case .songs: "songs"
        case .minutes: "minutes"
        case .hours: "hours"
        case .megabytes: "MB"
        case .gigabytes: "GB"
        }
    }
}

extension SmartPlaylist.Order {
    var title: String {
        switch self {
        case .random: "random"
        case .mostPlayed: "most played"
        case .leastPlayed: "least played"
        case .recentlyAdded: "most recently added"
        case .recentlyPlayed: "most recently played"
        case .highestRated: "highest rating"
        }
    }
}
