import SwiftUI

/// A small on/off capsule with an icon, such as the Done screen's "Video" and "Mix": outlined
/// while off, filled while on. `ChipButton` is an action in the same style.
struct ToggleChip: View {
    let icon: Icon
    let title: String
    let isOn: Bool
    /// What VoiceOver says, naming what pressing it does ("Show video").
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                IconView(icon, size: 13)
                Text(title)
            }
        }
        .buttonStyle(ToggleChipStyle(isOn: isOn))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// An action drawn like an off chip, such as the Done screen's "Open" and "Done".
struct ChipButton: View {
    var icon: Icon?
    let title: String
    /// What VoiceOver says, when it should say more than the title.
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { IconView(icon, size: 13) }
                Text(title)
            }
        }
        .buttonStyle(ToggleChipStyle(isOn: false))
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

private struct ToggleChipStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        ToggleChipBody(configuration: configuration, isOn: isOn)
    }
}

private struct ToggleChipBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .textStyle(.secondary)
            .foregroundStyle(isOn ? theme.text : theme.text2)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(isOn ? theme.fill2 : isHovered ? theme.fill : .clear, in: Capsule())
            .overlay {
                if !isOn {
                    Capsule().strokeBorder(theme.sep, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
    }
}
