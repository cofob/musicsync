import SwiftUI

/// Shared look of the media pages (modeled on Apple Music): red accent, big covers, capsule buttons.
extension Color {
    static let musicAccent = Color(red: 0.98, green: 0.14, blue: 0.24)
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

/// Light gray capsule with accent content, like Apple Music's "Play" button.
struct FilledCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.musicAccent)
            .padding(.horizontal, 18).frame(height: 32)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
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
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Circle())
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
struct MediaHeader<Cover: View, Content: View, Accessory: View>: View {
    @ViewBuilder var cover: Cover
    let title: String
    var canPlay = true
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .bottom, spacing: 30) {
            cover
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold)).lineLimit(3)
                content
                HStack(spacing: 10) {
                    PlayShuffleButtons(isEnabled: canPlay, onPlay: onPlay, onShuffle: onShuffle)
                    accessory
                }
                .padding(.top, 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
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
            Text(time.map(formatTime) ?? "").monospacedDigit().foregroundStyle(.secondary)
            RowMenu { menu }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: subtitle == nil ? 42 : 54)
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .contextMenu { menu }
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
            .buttonStyle(.plain).font(.title2.bold())
        } else {
            Text(title).font(.title2.bold())
        }
    }
}

/// Inline message for a page that failed to load, with a retry button.
struct LoadFailedView: View {
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
        RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary).frame(width: width, height: height)
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
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}
