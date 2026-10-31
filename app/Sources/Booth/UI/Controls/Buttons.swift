import SwiftUI

// Every control here is pure SwiftUI: AppKit-backed styles (bordered, link) and controls render
// as a "prohibited" box in ImageRenderer, which `--render-states` uses.

/// A text-only action such as "Cancel" or "Show in Finder": no chrome, dims while pressed.
struct TextActionButtonStyle: ButtonStyle {
    enum Tone { case primary, secondary }

    var tone: Tone = .secondary
    var weight: Font.Weight = .regular

    func makeBody(configuration: Configuration) -> some View {
        TextActionLabel(configuration: configuration, tone: tone, weight: weight)
    }
}

private struct TextActionLabel: View {
    let configuration: ButtonStyleConfiguration
    let tone: TextActionButtonStyle.Tone
    let weight: Font.Weight
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .textStyle(TextStyle.action.weight(weight))
            .foregroundStyle(tone == .primary ? theme.text : theme.text2)
            .lineLimit(1)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : isEnabled ? 1 : 0.5)
    }
}

/// The filled capsule for a screen's main action ("Save", "Choose another", "Try again").
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillLabel(configuration: configuration)
    }
}

private struct PillLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .textStyle(TextStyle.action.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(theme.inverse)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(theme.text, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : isEnabled ? 1 : 0.6)
    }
}

/// A 24 × 24 icon button (gear, back, close). A faint fill shows on hover and press.
struct IconButton: View {
    let icon: Icon
    let iconSize: CGFloat
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon, size: iconSize)
        }
        .buttonStyle(IconButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(theme.text2)
            .frame(width: 24, height: 24)
            .background(
                configuration.isPressed ? theme.fill2 : isHovered ? theme.fill : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { isHovered = $0 }
    }
}

/// No visual change of its own; for controls that draw their own pressed state.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
