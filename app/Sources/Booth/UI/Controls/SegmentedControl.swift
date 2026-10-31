import SwiftUI

/// Equal-width segments on a `fill2` well; the selected one is a raised `seg` chip in semibold.
struct SegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let accessibilityLabel: String
    let onSelect: (Option) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(theme.fill2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            onSelect(option)
        } label: {
            Text(title(option))
                .textStyle(TextStyle.action.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.seg)
                            .themeShadows(theme.segShadow, cornerRadius: 6)
                    }
                }
        }
        .buttonStyle(BareButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
