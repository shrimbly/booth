import SwiftUI

/// A vector icon in a square SVG view box, drawn from its SVG source.
struct Icon {
    enum Paint {
        /// Stroked with round caps and joins; the width is in view-box units, like SVG's.
        case stroke(width: CGFloat)
        case fill
    }

    let path: Path
    let viewBox: CGFloat
    let paint: Paint

    /// Lucide "settings" (classic), 24-unit box, stroke 2.
    static let gear: Icon = {
        var path = SVGPath.parse(
            "M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38"
                + "a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38"
                + "a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2"
                + "v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73"
                + "l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38"
                + "a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z")
        path.addEllipse(in: CGRect(x: 9, y: 9, width: 6, height: 6))
        return Icon(path: path, viewBox: 24, paint: .stroke(width: 2))
    }()

    /// Settings' back chevron, 18-unit box, stroke 1.8.
    static let back = Icon(path: SVGPath.parse("M11 4 L6 9 L11 14"), viewBox: 18, paint: .stroke(width: 1.8))

    /// The Error screen's dismiss cross, 16-unit box, stroke 1.6.
    static let close = Icon(
        path: SVGPath.parse("M4.5 4.5 L11.5 11.5 M11.5 4.5 L4.5 11.5"), viewBox: 16, paint: .stroke(width: 1.6))

    /// Lucide "film", 24-unit box. Stroke 2.2 so it reads as heavy as the gear at chip size.
    static let film: Icon = {
        var path = SVGPath.parse("M7 3v18 M3 7.5h4 M3 12h18 M3 16.5h4 M17 3v18 M17 7.5h4 M17 16.5h4")
        path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 2, height: 2))
        return Icon(path: path, viewBox: 24, paint: .stroke(width: 2.2))
    }()

    /// Lucide "sliders-horizontal", 24-unit box.
    static let sliders = Icon(
        path: SVGPath.parse(
            "M21 4H14 M10 4H3 M21 12H12 M8 12H3 M21 20H16 M12 20H3 M14 2V6 M8 10V14 M16 18V22"),
        viewBox: 24, paint: .stroke(width: 2.2))

    /// The Finder face: a rounded square split by the profile's nose, two eyes and a smile.
    /// 24-unit box, stroke 2, drawn to sit with the Lucide icons beside it.
    static let finder: Icon = {
        var path = SVGPath.parse(
            "M12.5 3 C 11.2 6.5 10.2 9.5 10.4 13 L 12.4 13 C 12.2 16 12.5 18.5 13 21"
                + " M8 8.5 V10 M16 8.5 V10 M7.5 15.5 C 10 17.6 14 17.6 16.5 15.5")
        path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 4, height: 4))
        return Icon(path: path, viewBox: 24, paint: .stroke(width: 2))
    }()

    static let play = Icon(path: SVGPath.parse("M4.5 2.6 L11.5 7 L4.5 11.4 Z"), viewBox: 14, paint: .fill)

    static let pause: Icon = {
        var path = Path()
        for x in [3.0, 8.0] {
            path.addRoundedRect(in: CGRect(x: x, y: 2.5, width: 3, height: 9), cornerSize: CGSize(width: 1, height: 1))
        }
        return Icon(path: path, viewBox: 14, paint: .fill)
    }()
}

/// Draws an `Icon` at `size` points in the current foreground style.
struct IconView: View {
    let icon: Icon
    let size: CGFloat

    init(_ icon: Icon, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        let shape = ScaledPath(path: icon.path, viewBox: icon.viewBox)
        Group {
            switch icon.paint {
            case .stroke(let width):
                shape.stroke(style: StrokeStyle(lineWidth: width * size / icon.viewBox, lineCap: .round, lineJoin: .round))
            case .fill:
                shape.fill()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A path in view-box units, scaled to fill its frame.
private struct ScaledPath: Shape {
    let path: Path
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
    }
}
