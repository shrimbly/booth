import AppKit
import SwiftUI

/// SF Pro at a size and weight, laid out on a fixed CSS-style line height (Popover.dc.html).
///
/// SwiftUI lays text out on the font's natural line height. CSS adds the difference as
/// half-leading above and below each line, so `textStyle(_:)` adds it as line spacing plus
/// half of it as vertical padding: one line is exactly `lineHeight` tall and baselines land
/// where the browser puts them.
struct TextStyle: Equatable {
    let size: CGFloat
    let weight: Font.Weight
    let lineHeight: CGFloat
    /// The height SwiftUI gives one line of this font: ascent and descent each rounded up to
    /// a whole point (measured: SF 15 → 19, 13 → 16, 12 → 15, at 1× and 2×).
    let naturalLineHeight: CGFloat

    init(size: CGFloat, weight: Font.Weight = .regular, lineHeight: CGFloat) {
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        let font = NSFont.systemFont(ofSize: size, weight: Self.appKitWeight(weight))
        naturalLineHeight = font.ascender.rounded(.up) + (-font.descender).rounded(.up) + font.leading
    }

    /// Screen titles: 15/20, weight 500.
    static let title = TextStyle(size: 15, weight: .medium, lineHeight: 20)
    /// The base text: 13/17 (Settings rows).
    static let body = TextStyle(size: 13, lineHeight: 17)
    /// Status and meta lines: 12/16.
    static let secondary = TextStyle(size: 12, lineHeight: 16)
    /// Wrapping explanations (first run, errors): 12/17.
    static let paragraph = TextStyle(size: 12, lineHeight: 17)
    /// Text buttons inherit the base 17 pt line height at 12 pt (`font: inherit; font-size: 12px`).
    static let action = TextStyle(size: 12, lineHeight: 17)

    func weight(_ weight: Font.Weight) -> TextStyle {
        TextStyle(size: size, weight: weight, lineHeight: lineHeight)
    }

    var font: Font { .system(size: size, weight: weight) }

    fileprivate var halfLeading: CGFloat { max(0, lineHeight - naturalLineHeight) / 2 }

    private static func appKitWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
}

extension View {
    /// Sets the font and the CSS line height described by `style`.
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font)
            .lineSpacing(style.halfLeading * 2)
            .padding(.vertical, style.halfLeading)
    }
}
