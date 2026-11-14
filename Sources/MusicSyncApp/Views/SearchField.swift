import SwiftUI

/// Wide search field centered in the window toolbar, the same on every page (Apple Music style, red focus ring).
/// On the Search page it searches globally with a suggestion dropdown; elsewhere it filters the page ("Find in …").
struct ToolbarSearchField: View {
    @Environment(AppModel.self) private var model
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let search = model.search
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $model.searchText, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { if model.selection == .search { search.submit(model.searchText) } }
                .onKeyPress(.downArrow) { arrow(1) }
                .onKeyPress(.upArrow) { arrow(-1) }
                .onExitCommand { search.showsSuggestions = false }
            if !model.searchText.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { model.searchText = "" }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 400, height: 30)
        .background(.background.opacity(0.6), in: Capsule())
        .overlay {
            Capsule().strokeBorder(focused ? Color.musicAccent.opacity(0.45) : Color.primary.opacity(0.12), lineWidth: focused ? 3 : 1)
        }
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.15), value: focused)
        .onChange(of: focused) { model.searchFieldFocused = focused }
        .onChange(of: model.searchFocusRequest) { focused = true }
        .onAppear { if model.selection == .search { focused = true } }
    }

    private func arrow(_ delta: Int) -> KeyPress.Result {
        let search = model.search
        guard model.selection == .search, !model.searchText.isEmpty else { return .ignored }
        if !search.showsSuggestions { search.showsSuggestions = true; return .handled }
        search.move(delta)
        return .handled
    }
}

/// "Library | iPod" switch at the top right of the Search page.
struct SearchScopePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var search = model.search
        Picker("Search In", selection: $search.scope) {
            Text("Library").tag(SearchModel.Scope.library)
            Text("iPod").tag(SearchModel.Scope.ipod)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Dropdown under the search field: completions, then artists, albums and songs.
struct SearchSuggestionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.search
        let suggestions = search.suggestions
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.completions.enumerated()), id: \.offset) { index, text in
                row(index) {
                    model.searchText = text
                    search.commit(text)
                } content: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 20)
                    Text(text).lineLimit(1)
                }
                .frame(height: 30)
            }
            if !suggestions.completions.isEmpty && !suggestions.items.isEmpty {
                Divider().padding(.vertical, 4).padding(.horizontal, 8)
            }
            ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { offset, item in
                let index = suggestions.completions.count + offset
                row(index) { search.open(item) } content: {
                    SearchItemArtwork(item: item).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        Text(item.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(height: 52)
                .overlay(alignment: .bottom) {
                    if offset < suggestions.items.count - 1 { Divider().padding(.leading, 62).padding(.trailing, 8) }
                }
            }
        }
        .padding(6)
        .frame(width: 440)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    private func row<Content: View>(_ index: Int, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        let search = model.search
        return Button(action: action) {
            HStack(spacing: 10) { content(); Spacer(minLength: 0) }
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .background(search.highlighted == index ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { search.highlighted = index } }
    }
}

/// Cover for a search item; round for artists.
struct SearchItemArtwork: View {
    let item: SearchModel.Item

    var body: some View {
        switch item {
        case .artist(let a): CoverImage(id: a.coverArt, size: 120, cornerRadius: 0, symbol: "music.microphone").clipShape(Circle())
        case .album(let a): CoverImage(id: a.coverArt, size: 120, cornerRadius: 5)
        case .song(let s): CoverImage(id: s.coverArt, size: 120, cornerRadius: 5)
        case .deviceAlbum(let a): DeviceCoverImage(imageID: a.imageID, cornerRadius: 5)
        case .deviceTrack(let t): DeviceCoverImage(imageID: t.imageID, cornerRadius: 5)
        }
    }
}

extension SearchModel.Item {
    var title: String {
        switch self {
        case .artist(let a): a.name
        case .album(let a): a.name
        case .song(let s): s.title
        case .deviceAlbum(let a): a.name
        case .deviceTrack(let t): t.title
        }
    }

    /// "Artist", "Album · Artist", "Song · Artist".
    var subtitle: String {
        func join(_ kind: String, _ artist: String?) -> String { [kind, artist].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ") }
        return switch self {
        case .artist: "Artist"
        case .album(let a): join("Album", a.artistName)
        case .song(let s): join("Song", s.artistName)
        case .deviceAlbum(let a): join("Album", a.artist)
        case .deviceTrack(let t): join("Song", t.artist)
        }
    }

    var isSong: Bool {
        switch self {
        case .song, .deviceTrack: true
        default: false
        }
    }
}
