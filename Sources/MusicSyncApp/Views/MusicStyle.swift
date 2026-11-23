import SwiftUI

/// Shared look of the media pages: red accent, big covers, capsule buttons.
extension Color {
    /// Settings > Appearance; red by default. Views that read it draw again when it changes.
    @MainActor static var musicAccent: Color { AppPreferences.shared.appearance.accent.color }
}

/// Sidebar row with an accent-colored symbol.
struct AccentLabel: View {
    let title: String
    let symbol: String
    var isSelected = false

    var body: some View {
        Label { Text(title).fontWeight(isSelected ? .semibold : nil) } icon: { Image(systemName: symbol).foregroundStyle(Color.musicAccent) }
    }
}

extension View {
    /// Liquid Glass on macOS 26, a material with a hairline border before.
    @ViewBuilder func glass<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

extension View {
    /// Content fades under the toolbar without a divider line (macOS 26).
    @ViewBuilder func softTopEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }
}

/// Light gray capsule with accent content, for the "Play" button.
struct FilledCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.musicAccent)
            .padding(.horizontal, 18).frame(height: 32)
            .animation(.press) { $0.background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule()) }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// Round icon button on a light gray disc.
struct CircleIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.musicAccent)
            .frame(width: size, height: size)
            .animation(.press) { $0.background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Circle()) }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
    }
}

/// Capsule "Play" and "Shuffle" buttons.
struct PlayShuffleButtons: View {
    var isEnabled = true
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) { Label("Play", systemImage: "play.fill").frame(minWidth: 80) }
            Button(action: onShuffle) { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 80) }
        }
        .buttonStyle(FilledCapsuleStyle())
        .disabled(!isEnabled)
    }
}

/// Big cover on the left; bold title, free-form details, Play / Shuffle and an accessory on the right.
/// When the page is too narrow for both, the details go under the cover.
struct MediaHeader<Cover: View, Content: View, Accessory: View>: View {
    @ViewBuilder var cover: Cover
    let title: String
    var canPlay = true
    /// Set for titles the user may change: the title becomes a text field.
    var onRename: ((String) -> Void)?
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let art = cover.frame(width: 260, height: 260).shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 30) { art; info; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 24) { art; info }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                if let onRename {
                    InlineTextField(text: title, prompt: "Name", font: .system(size: 30, weight: .bold), onCommit: onRename)
                } else {
                    Text(title).font(.system(size: 30, weight: .bold)).lineLimit(3)
                }
                content
            }
            // A long title wraps, so only the buttons decide whether the details fit beside the cover.
            .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                PlayShuffleButtons(isEnabled: canPlay, onPlay: onPlay, onShuffle: onShuffle)
                accessory
            }
            .padding(.top, 14)
        }
    }
}

extension MediaHeader where Accessory == EmptyView {
    init(@ViewBuilder cover: () -> Cover, title: String, canPlay: Bool = true, onPlay: @escaping () -> Void,
         onShuffle: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(cover: cover, title: title, canPlay: canPlay, onPlay: onPlay, onShuffle: onShuffle, content: content) { EmptyView() }
    }
}

/// Accent "•••" row menu.
struct RowMenu<Items: View>: View {
    /// White on a selected (blue) table row, accent elsewhere.
    var tint = Color.musicAccent
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(tint)
        }
        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
    }
}

/// Song row: leading slot (number or cover), title and subtitle, time and a "•••" menu.
/// The parent handles clicks and draws separators.
struct TrackRow<Leading: View, MenuItems: View>: View {
    let title: String
    var subtitle: String?
    let time: TimeInterval?
    var isCurrent = false
    var isSelected = false
    /// Edges next to another selected row: the selection draws as one block, rounded only at its ends.
    var joined: VerticalEdge.Set = []
    /// Small star before the time.
    var isStarred = false
    /// Small gray symbol before the time, e.g. the download state.
    var badge: String?
    /// Gray text before the time: the song columns of Settings > Appearance.
    var detail: String?
    /// Short gray label before the star, e.g. why a song is downloaded.
    var tag: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var menu: MenuItems

    var body: some View {
        HStack(spacing: 14) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).foregroundStyle(isCurrent ? Color.musicAccent : .primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
            if let tag {
                Text(tag).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
            if isStarred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.musicAccent) }
            if let badge { Image(systemName: badge).font(.caption).foregroundStyle(.secondary) }
            Text(time.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.secondary)
            RowMenu { menu }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: AppPreferences.shared.appearance.listDensity.rowHeight(twoLines: subtitle != nil))
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: selectionShape)
        .contentShape(Rectangle())
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([title, subtitle, time.map(spokenTime)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectionShape: UnevenRoundedRectangle {
        let top: CGFloat = joined.contains(.top) ? 0 : 8, bottom: CGFloat = joined.contains(.bottom) ? 0 : 8
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
    }
}

/// Track number, or a speaker when the row is playing.
struct TrackNumber: View {
    let text: String
    var isCurrent = false

    var body: some View {
        Group {
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.musicAccent)
            } else {
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, alignment: .leading)
    }
}

/// "Song ... Time" header above track lists.
struct TrackListHeader: View {
    var body: some View {
        HStack {
            Text("Song")
            Spacer()
            Text("Time").padding(.trailing, 40)
        }
        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.bottom, 4)
    }
}

/// Section title of a page, optionally with a chevron that opens a full list.
struct ShelfHeader: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(HitAreaButtonStyle()).font(.title2.bold())
        } else {
            Text(title).font(.title2.bold())
        }
    }
}

/// Inline message for a page that failed to load, with a retry button. It also tries again by itself once the
/// server answers (`DownloadsModel.retrySoon`).
struct LoadFailedView: View {
    @Environment(AppModel.self) private var model
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry).buttonStyle(FilledCapsuleStyle())
        }
        // Asked again after each retry: a page that keeps its message on a failed retry waits for the next ping.
        .task(id: model.downloads.reconnects) { model.downloads.retrySoon() }
        .onChange(of: model.downloads.reconnects) { retry() }
        .onAppear { PageProbe.failures += 1 }
        .onDisappear { PageProbe.failures -= 1 }
    }
}

// MARK: Loading placeholders (final layout from the first frame, so nothing shifts when data arrives)

/// Softly pulsing placeholder fill.
struct Shimmer: ViewModifier {
    func body(content: Content) -> some View {
        content.phaseAnimator([0.55, 1.0]) { view, phase in
            view.opacity(phase)
        } animation: { _ in .easeInOut(duration: 0.9) }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// Gray rounded block.
struct PlaceholderBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var cornerRadius: CGFloat = 4

    var body: some View {
        // Max width, not a fixed one: in a narrow column the blocks shrink and the page does not overflow.
        RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary).frame(maxWidth: width).frame(height: height)
            .onAppear { PageProbe.placeholders += 1 }
            .onDisappear { PageProbe.placeholders -= 1 }
    }
}

/// Album card placeholder: cover square and two text lines.
struct PlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(1, contentMode: .fit)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 4)
            PlaceholderBlock(width: 120, height: 12)
            PlaceholderBlock(width: 80, height: 12)
        }
        .shimmering()
    }
}

/// Song row placeholders matching `TrackRow`.
struct PlaceholderRows: View {
    var count = 8
    var cover = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 14) {
                    if cover { PlaceholderBlock(width: 40, height: 40) } else { PlaceholderBlock(width: 18, height: 12) }
                    PlaceholderBlock(width: CGFloat(140 + (i * 37) % 120), height: 12)
                    Spacer()
                    PlaceholderBlock(width: 34, height: 12)
                }
                .padding(.horizontal, 10).frame(height: cover ? 54 : 42)
                .overlay(alignment: .bottom) { Divider().padding(.leading, cover ? 64 : 42) }
            }
        }
        .shimmering()
    }
}

/// Plain button that takes clicks in its whole frame. `.plain` takes them only on the drawn icon or text,
/// so a frame or background set outside the button is not clickable.
struct HitAreaButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var width: CGFloat?
    var height: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .animation(.press) { $0.opacity(configuration.isPressed ? 0.6 : 1) }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A pressed card shrinks a little with an animation; `.plain` dims it at once instead.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .animation(.press) { $0.scaleEffect(configuration.isPressed ? 0.97 : 1) }
    }
}

extension Animation {
    /// Press feedback of every button style: short, so a click never feels slow, but never a jump.
    static let press = Animation.easeOut(duration: 0.12)
}
