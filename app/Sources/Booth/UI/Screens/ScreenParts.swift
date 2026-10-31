import SwiftUI

/// A screen's title: 15/20 weight 500 on one line, clear of the corner button.
struct ScreenTitle: View {
    let text: String
    /// Keeps clear of the frame's corner button (gear or ×), on screens that have one.
    var clearsCorner = true

    init(_ text: String, clearsCorner: Bool = true) {
        self.text = text
        self.clearsCorner = clearsCorner
    }

    var body: some View {
        Text(text)
            .textStyle(.title)
            .lineLimit(1)
            // File names keep their extension visible, as in Finder.
            .truncationMode(.middle)
            .padding(.trailing, clearsCorner ? 24 : 0)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One line of secondary text: 12/16 `text2` with tabular figures.
struct SecondaryLine: View {
    let text: String

    init(_ text: String) { self.text = text }

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .textStyle(.secondary)
            .monospacedDigit()
            .foregroundStyle(theme.text2)
            .lineLimit(1)
    }
}

/// A wrapping explanation: 12/17 `text2`.
struct Paragraph: View {
    let text: String

    init(_ text: String) { self.text = text }

    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .textStyle(.paragraph)
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// How far a footer sits above the frame's inner bottom edge: text actions at 11, rows that
/// hold a 24 pt pill at 9 (the two line up optically).
enum FooterInset: CGFloat {
    case text = 11
    case pill = 9
}

extension View {
    func footerInset(_ inset: FooterInset) -> some View {
        padding(.bottom, inset.rawValue)
    }
}
