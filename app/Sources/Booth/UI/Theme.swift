import AppKit
import BoothCore
import SwiftUI

/// A CSS `box-shadow` layer. `spread` without `blur` is a hairline ring.
struct ThemeShadow: Equatable {
    var color: Color
    var x: CGFloat
    var y: CGFloat
    var blur: CGFloat
    var spread: CGFloat = 0
}

/// Popover colour tokens (SPEC §3.1, Popover.dc.html `THEME`). Token names match the mockup
/// so values can be cross-checked at a glance. Resolve with `Theme.resolve(colorScheme)`.
struct Theme {
    var glass: Color
    var text: Color
    var dim: Color
    /// Base of the signature colour; letters use `sig(alpha:)`.
    var sigRGB: (red: Double, green: Double, blue: Double)
    var sigOver: Color
    var text2: Color
    var sep: Color
    var fill: Color
    var fill2: Color
    var track: Color
    var dash: Color
    var border: Color
    var wave: Color
    var knob: Color
    var inverse: Color
    var seg: Color
    var segShadow: [ThemeShadow]
    var toggleOn: Color
    var toggleOff: Color
    /// The Working bar (WorkingSound.dc.html): its fill, the rings inside it, the text on it,
    /// and the empty track. The fill is dark in light mode and light in dark mode.
    var ink0: Color
    var ink3: Color
    var onInk: Color
    var inkTrack: Color

    /// Progress bars, the working lamp, the background-job dot.
    static let work = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

    /// Slider knob: `0 0.5px 2px rgba(0,0,0,.35), 0 0 0 0.5px rgba(0,0,0,.12)` in both appearances.
    static let knobShadow = [
        ThemeShadow(color: .black.opacity(0.35), x: 0, y: 0.5, blur: 2),
        ThemeShadow(color: .black.opacity(0.12), x: 0, y: 0, blur: 0, spread: 0.5),
    ]

    /// Switch knob: `0 1px 2px rgba(0,0,0,.3)`.
    static let toggleKnobShadow = [ThemeShadow(color: .black.opacity(0.3), x: 0, y: 1, blur: 2)]

    /// The signature's resting colour, `rgba(sigRgb, alpha)`.
    func sig(alpha: Double) -> Color {
        Color(red: sigRGB.red / 255, green: sigRGB.green / 255, blue: sigRGB.blue / 255, opacity: alpha)
    }

    func color(for ink: SignatureInk) -> Color {
        switch ink {
        case .resting(let alpha): sig(alpha: alpha)
        case .over: sigOver
        }
    }

    /// `glass` at full opacity: the panel colour for snapshots, which have no visual effect view
    /// behind them.
    var solidGlass: Color {
        Color(nsColor: NSColor(glass).withAlphaComponent(1))
    }

    static func resolve(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }

    static let light = Theme(
        glass: rgba(250, 250, 249, 0.82),
        text: hex(0x1D1D1F),
        dim: rgba(29, 29, 31, 0.74),
        sigRGB: (60, 60, 67),
        sigOver: rgba(29, 29, 31, 0.9),
        text2: rgba(60, 60, 67, 0.76),
        sep: rgba(0, 0, 0, 0.08),
        fill: rgba(0, 0, 0, 0.04),
        fill2: rgba(0, 0, 0, 0.07),
        track: rgba(0, 0, 0, 0.10),
        dash: rgba(60, 60, 67, 0.38),
        border: rgba(0, 0, 0, 0.10),
        wave: rgba(60, 60, 67, 0.22),
        knob: hex(0xFFFFFF),
        inverse: hex(0xFFFFFF),
        seg: hex(0xFFFFFF),
        segShadow: [
            ThemeShadow(color: rgba(0, 0, 0, 0.12), x: 0, y: 1, blur: 2),
            ThemeShadow(color: rgba(0, 0, 0, 0.06), x: 0, y: 0, blur: 0, spread: 0.5),
        ],
        toggleOn: hex(0x1D1D1F),
        toggleOff: rgba(0, 0, 0, 0.14),
        ink0: hex(0x1D1D1F),
        ink3: hex(0x8E8E93),
        onInk: hex(0xFFFFFF),
        inkTrack: rgba(0, 0, 0, 0.07))

    static let dark = Theme(
        glass: rgba(38, 38, 40, 0.78),
        text: hex(0xF5F5F7),
        dim: rgba(245, 245, 247, 0.74),
        sigRGB: (235, 235, 245),
        sigOver: rgba(245, 245, 247, 0.9),
        text2: rgba(235, 235, 245, 0.70),
        sep: rgba(255, 255, 255, 0.09),
        fill: rgba(255, 255, 255, 0.05),
        fill2: rgba(255, 255, 255, 0.09),
        track: rgba(255, 255, 255, 0.14),
        dash: rgba(235, 235, 245, 0.36),
        border: rgba(255, 255, 255, 0.12),
        wave: rgba(235, 235, 245, 0.22),
        knob: hex(0xECECEE),
        inverse: hex(0x1D1D1F),
        seg: rgba(255, 255, 255, 0.18),
        segShadow: [ThemeShadow(color: rgba(0, 0, 0, 0.3), x: 0, y: 1, blur: 2)],
        toggleOn: hex(0x8E8E93),
        toggleOff: rgba(255, 255, 255, 0.16),
        ink0: hex(0xF5F5F7),
        ink3: hex(0x8E8E93),
        onInk: hex(0x1D1D1F),
        inkTrack: rgba(255, 255, 255, 0.09))

    private static func rgba(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }

    private static func hex(_ value: UInt32) -> Color {
        rgba(Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF), 1)
    }
}

extension View {
    /// Applies the layers of a CSS-style shadow list. Rings (spread, no blur) become a stroke.
    func themeShadows(_ shadows: [ThemeShadow], cornerRadius: CGFloat) -> some View {
        shadows.reduce(AnyView(self)) { view, shadow in
            if shadow.blur == 0 && shadow.spread > 0 {
                return AnyView(view.overlay(
                    RoundedRectangle(cornerRadius: cornerRadius + shadow.spread / 2, style: .continuous)
                        .inset(by: -shadow.spread / 2)
                        .stroke(shadow.color, lineWidth: shadow.spread)
                        .allowsHitTesting(false)))
            }
            // CSS blur is roughly twice SwiftUI's shadow radius.
            return AnyView(view.shadow(color: shadow.color, radius: shadow.blur / 2, x: shadow.x, y: shadow.y))
        }
    }
}
