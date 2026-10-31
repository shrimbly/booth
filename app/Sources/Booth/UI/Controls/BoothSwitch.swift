import SwiftUI

/// The Settings switch: a 32 × 18 track with a white 14 pt knob that springs across with a
/// slight overshoot. VoiceOver sees a standard toggle.
struct BoothSwitch: View {
    let label: String
    let isOn: Bool
    let onToggle: (Bool) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            onToggle(!isOn)
        } label: {
            Capsule()
                .fill(isOn ? theme.toggleOn : theme.toggleOff)
                .animation(PopoverMotion.switchTrack, value: isOn)
                .frame(width: 32, height: 18)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .themeShadows(Theme.toggleKnobShadow, cornerRadius: 7)
                        .offset(x: isOn ? 16 : 2)
                        .animation(reduceMotion ? PopoverMotion.switchTrack : PopoverMotion.switchKnob, value: isOn)
                }
        }
        .buttonStyle(BareButtonStyle())
        .accessibilityRepresentation {
            Toggle(label, isOn: Binding(get: { isOn }, set: onToggle))
        }
    }
}
