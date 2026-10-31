import AppKit
import SwiftUI

/// Frosted glass for Booth's own windows (SPEC §3.2): a behind-window blur under the theme's
/// `glass` tint, rounded, with a 0.5 pt `border` hairline. The capsule puts its content on top
/// as subviews; the popover lays it out under its SwiftUI content (`GlassBackground`).
///
/// Corners are continuous (squircle) unless `continuousCorners` is false, as for the capsule,
/// whose ends stay round.
final class GlassChromeView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()

    init(cornerRadius: CGFloat, continuousCorners: Bool = true, material: NSVisualEffectView.Material = .popover) {
        let edge = 2 * Self.capInset(cornerRadius: cornerRadius, continuous: continuousCorners) + 1
        super.init(frame: NSRect(x: 0, y: 0, width: edge, height: edge))
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = continuousCorners ? .continuous : .circular
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        effectView.material = material
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        // A layer corner radius does not clip a behind-window blur; a mask image does.
        effectView.maskImage = Self.roundedMask(cornerRadius: cornerRadius, continuous: continuousCorners)
        tintView.wantsLayer = true
        for view in [effectView, tintView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let theme = effectiveAppearance.isDark ? Theme.dark : Theme.light
        tintView.layer?.backgroundColor = NSColor(theme.glass).cgColor
        // The layer border is composited above the sublayers, so it stays on top of the content.
        layer?.borderColor = NSColor(theme.border).cgColor
    }

    /// How far a corner's curve reaches along each edge: a continuous corner eases into the
    /// straight edge over about 1.53 times its radius.
    private static func capInset(cornerRadius radius: CGFloat, continuous: Bool) -> CGFloat {
        continuous ? ceil(radius * 1.6) : radius
    }

    /// A stretchable rounded rectangle: only the corners keep their shape when resized.
    private static func roundedMask(cornerRadius radius: CGFloat, continuous: Bool) -> NSImage {
        let cap = capInset(cornerRadius: radius, continuous: continuous)
        let edge = 2 * cap + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let shape = RoundedRectangle(cornerRadius: radius, style: continuous ? .continuous : .circular)
            context.addPath(shape.path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}

/// `GlassChromeView` as a SwiftUI background, so the glass takes part in SwiftUI's layout and
/// animations: the popover's glass grows and shrinks with its frame, frame for frame. Live
/// windows only: ImageRenderer cannot draw AppKit views.
struct GlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> GlassChromeView {
        GlassChromeView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ nsView: GlassChromeView, context: Context) {}
}
