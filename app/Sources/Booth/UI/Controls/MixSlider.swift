import AppKit
import SwiftUI

/// One Done-screen mixer row: a 76 pt label, then a 2 pt track with a 12 pt knob. No value
/// label. Drag the knob from wherever it was taken, or press the bare track to jump there;
/// arrow keys step by 1. A press on the knob that does not move changes nothing.
struct MixSlider: View {
    let label: String
    /// 0…100
    let value: Int
    let onChange: (Int) -> Void

    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool
    /// Where the pointer took the knob, from the knob's centre, for the length of a drag.
    @State private var grabOffset: CGFloat?
    /// Focus came from the pointer, so the ring (a keyboard cue) stays hidden until a key is
    /// pressed or focus moves on.
    @State private var isPointerFocused = false

    private static let knobSize: CGFloat = 12
    private static let rowHeight: CGFloat = 24
    /// A press this close to the knob's centre takes the knob rather than jumping.
    private static let grabRadius: CGFloat = 8

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .textStyle(.secondary)
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            track
        }
        .frame(height: Self.rowHeight)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }), in: 0...100, step: 1) {
                Text(label)
            }
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            let travel = max(0, proxy.size.width - Self.knobSize)
            let knobX = travel * Double(value) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track).frame(height: 2)
                Capsule().fill(theme.text).frame(width: knobX + Self.knobSize / 2, height: 2)
                knob.offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if grabOffset == nil {
                        isPointerFocused = true
                        let knobCentre = knobX + Self.knobSize / 2
                        let offset = drag.startLocation.x - knobCentre
                        if abs(offset) <= Self.grabRadius {
                            // Took the knob: it moves with the pointer from here on.
                            grabOffset = offset
                            return
                        }
                        // Pressed the bare track: like an HTML range input, the knob jumps
                        // there and its centre follows the pointer.
                        grabOffset = 0
                    }
                    let knobLeft = drag.location.x - (grabOffset ?? 0) - Self.knobSize / 2
                    let fraction = travel > 0 ? knobLeft / travel : 0
                    set(Int((fraction * 100).rounded()))
                }
                .onEnded { _ in grabOffset = nil })
        }
        .frame(height: Self.rowHeight)
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onChange(of: isFocused) { _, focused in
            if !focused { isPointerFocused = false }
        }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .onKeyPress(.upArrow) { step(1) }
    }

    private var knob: some View {
        Circle()
            .fill(theme.knob)
            .frame(width: Self.knobSize, height: Self.knobSize)
            .themeShadows(Theme.knobShadow, cornerRadius: Self.knobSize / 2)
            .overlay {
                if isFocused && !isPointerFocused {
                    Circle()
                        .stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                        .padding(-2.5)
                }
            }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        isPointerFocused = false
        set(value + delta)
        return .handled
    }

    private func set(_ newValue: Int) {
        let clamped = min(100, max(0, newValue))
        if clamped != value { onChange(clamped) }
    }
}
