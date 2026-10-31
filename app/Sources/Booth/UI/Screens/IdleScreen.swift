import SwiftUI

/// Ready for a file. While one is dragged over the popover the prompt turns to "Release to
/// start" and the chooser link fades out.
struct IdleScreen: View {
    let model: AppModel

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isOver = model.dropHover
        VStack(alignment: .leading, spacing: 0) {
            // One prompt hands over to the other out of focus, in the same place.
            ZStack(alignment: .topLeading) {
                Text(isOver ? "Release to start" : "Drop audio or video")
                    .foregroundStyle(isOver ? theme.text : theme.dim)
                    .id(isOver)
                    .transition(.swap(reduceMotion: reduceMotion, blur: 3))
            }
            .textStyle(.title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(PopoverMotion.dropHover, value: isOver)
            .padding(.trailing, 24)
            Button("or choose a file", action: model.chooseFiles)
                .buttonStyle(UnderlinedLinkStyle())
                // The hover fill's padding hangs outside the text's column.
                .padding(.leading, -6)
                .opacity(isOver ? 0 : 1)
                .animation(PopoverMotion.ease(0.12), value: isOver)
                .allowsHitTesting(!isOver)
                .accessibilityHidden(isOver)
        }
    }
}

/// "or choose a file": 12 pt `text2`, underlined 2 pt below the baseline. Under the pointer it
/// darkens to `text` on a soft rounded fill.
private struct UnderlinedLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        UnderlinedLinkLabel(configuration: configuration)
    }
}

private struct UnderlinedLinkLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .textStyle(.action)
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .lastTextBaseline)) {
                // SwiftUI's own underline has no offset control; this matches
                // `text-underline-offset: 2px`.
                Rectangle()
                    .frame(height: 1)
                    .alignmentGuide(.lastTextBaseline) { _ in -2 }
            }
            .foregroundStyle(isHovered ? theme.text : theme.text2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(isHovered ? theme.fill2 : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(PopoverMotion.ease(0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
