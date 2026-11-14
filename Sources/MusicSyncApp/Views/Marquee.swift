import SwiftUI

/// One line of text that scrolls sideways, again and again, when it does not fit.
struct Marquee: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap: CGFloat = 40

    var body: some View {
        let scrolls = textWidth > boxWidth + 1 && !reduceMotion
        Text(text).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .overlay(alignment: .leading) {
                HStack(spacing: gap) {
                    label
                    if scrolls { label }
                }
                .offset(x: offset)
            }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: scrolls ? .clear : .black, location: 0), .init(color: .black, location: 0.04),
                                       .init(color: .black, location: 0.92), .init(color: scrolls ? .clear : .black, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .task(id: [text, scrolls ? "on" : "off"]) {
                offset = 0
                guard scrolls else { return }
                let distance = textWidth + gap
                while !Task.isCancelled {
                    guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                    withAnimation(.linear(duration: distance / 30)) { offset = -distance }
                    guard (try? await Task.sleep(for: .seconds(distance / 30))) != nil else { return }
                    offset = 0
                }
            }
    }

    private var label: some View {
        Text(text).lineLimit(1).fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
    }
}
