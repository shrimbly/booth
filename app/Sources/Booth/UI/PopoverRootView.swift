import BoothCore
import SwiftUI

/// The popover's content (Popover.dc.html): the panel's padding around the frame that holds
/// the signature, the corner button, the current screen and its footer. 320 pt wide; the
/// height hugs the content.
///
/// In the live panel the background is the shell's frosted glass (visual effect, tint, 0.5 pt
/// border, radius 14), laid out here so it grows and shrinks with the frame in one animation;
/// the window around it is clear, and handles drags at the AppKit level. Snapshots draw a solid
/// glass panel instead.
///
/// Everything is pure SwiftUI (shapes, text, plain buttons, gestures): AppKit-backed controls
/// render as a "prohibited" box in ImageRenderer, which `--render-states` uses.
struct PopoverRootView: View {
    let model: AppModel
    let chrome: PopoverChrome

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 320
    /// The panel's 6 pt padding plus its 0.5 pt border, which takes up room in the mockup's
    /// border-box layout: the frame is 307 pt wide, its content 274.
    static let panelInset: CGFloat = 6.5
    /// While a file is in the booth the progress bar sits closer to the glass: 4 pt padding.
    static let workingPanelInset: CGFloat = 4.5
    static let panelBorderWidth: CGFloat = 0.5
    static let panelCornerRadius: CGFloat = 14
    /// The glass's own coordinates, top left at its corner.
    static let glassSpace = "popover-glass"

    init(model: AppModel, chrome: PopoverChrome = .live) {
        self.model = model
        self.chrome = chrome
    }

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        PopoverFrame(model: model)
            .padding(model.effectiveScreen == .working ? Self.workingPanelInset : Self.panelInset)
            .frame(width: Self.width)
            .coordinateSpace(.named(Self.glassSpace))
            .background {
                switch chrome {
                case .live:
                    GlassBackground(cornerRadius: Self.panelCornerRadius)
                case .snapshot:
                    RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                        .fill(theme.solidGlass)
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
                                .strokeBorder(theme.border, lineWidth: Self.panelBorderWidth)
                        }
                }
            }
            // A screen change resizes the frame and the glass together, and cross-fades the
            // content.
            .animation(PopoverMotion.unlessReduced(PopoverMotion.screenChange, reduceMotion), value: model.effectiveScreen)
            // Pinned to the top while the panel animates to a new height.
            .frame(maxHeight: .infinity, alignment: .top)
            .font(TextStyle.body.font)
            .foregroundStyle(theme.text)
            .environment(\.theme, theme)
            .environment(\.popoverChrome, chrome)
    }
}

/// The rounded frame inside the panel (SPEC §3.3). Only the drop zone draws its outline, and
/// on the Working screen the progress bar fills the whole frame.
private struct PopoverFrame: View {
    let model: AppModel

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cornerRadius: CGFloat = 10
    static let borderWidth: CGFloat = 1.5
    static let idleMinHeight: CGFloat = 156

    var body: some View {
        let screen = model.effectiveScreen
        let frameStyle = PopoverLogic.frameStyle(screen: screen, dropHover: model.dropHover)
        let isDropTarget = frameStyle == .dropTarget
        ZStack(alignment: .topLeading) {
            screenContent(screen)
                .transition(.screenSwap(reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(Self.contentInsets(screen))
        .frame(minHeight: screen == .idle ? Self.idleMinHeight - 2 * Self.borderWidth : 0, alignment: .top)
        .background(alignment: .bottomLeading) {
            if screen.showsSignature {
                SignatureView(screen: screen, progress: model.workingJob?.progress ?? 0, dropHover: model.dropHover)
                    .padding(.leading, 16)
                    .padding(.bottom, 2)
                    .transition(.swap(reduceMotion: reduceMotion, arriving: .last))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack(alignment: .bottomTrailing) {
                // Ideal size: footers never truncate (a ZStack otherwise squeezes a label to "S…").
                footer(screen)
                    .fixedSize()
                    .transition(.swap(reduceMotion: reduceMotion, blur: 2, arriving: .last))
            }
            .padding(.trailing, screen == .firstrun ? 12 : 15)
        }
        .overlay(alignment: .topTrailing) {
            ZStack {
                cornerButton(screen)
                    .transition(.swap(reduceMotion: reduceMotion, blur: 2))
            }
            .padding(4)
        }
        .padding(screen == .working ? 0 : Self.borderWidth)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(isDropTarget ? theme.fill : Color.clear)
                .animation(PopoverMotion.dropHover, value: isDropTarget)
        }
        .overlay {
            FrameBorder(style: frameStyle, cornerRadius: Self.cornerRadius, lineWidth: Self.borderWidth)
                .animation(PopoverMotion.outlineJoin, value: frameStyle)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    /// Room around each screen's content. The bottom leaves space for the signature or footer:
    /// Done keeps its actions in the content, and Working is all progress bar.
    static func contentInsets(_ screen: PopoverScreen) -> EdgeInsets {
        let bottom: CGFloat
        switch screen {
        case .working: return EdgeInsets()
        case .idle: bottom = 13
        case .done: bottom = 14
        case .settings: bottom = 42
        case .error: bottom = 46
        case .firstrun: bottom = 66
        }
        return EdgeInsets(top: 13, leading: 15, bottom: bottom, trailing: 15)
    }

    @ViewBuilder
    private func screenContent(_ screen: PopoverScreen) -> some View {
        switch screen {
        case .idle: IdleScreen(model: model)
        case .firstrun: FirstRunScreen(model: model)
        case .working: WorkingScreen(model: model)
        case .done: DoneScreen(model: model)
        case .settings: SettingsScreen(model: model)
        case .error: ErrorScreen(model: model)
        }
    }

    @ViewBuilder
    private func footer(_ screen: PopoverScreen) -> some View {
        switch screen {
        case .idle, .working, .done: EmptyView()
        case .firstrun: FirstRunFooter(model: model)
        case .settings: SettingsFooter(model: model)
        case .error: ErrorFooter(model: model)
        }
    }

    @ViewBuilder
    private func cornerButton(_ screen: PopoverScreen) -> some View {
        if screen == .error {
            IconButton(icon: .close, iconSize: 14, label: "Dismiss", action: model.dismissError)
        } else if screen.showsGear {
            IconButton(icon: .gear, iconSize: 15, label: "Settings", action: model.showSettings)
        }
    }
}

/// The frame's 1.5 pt border: the drop zone's round dots (CSS `dotted`), a solid line under a
/// dragged file, or nothing. Between dots and line the dots stretch into dashes and close up, so
/// the outline visibly joins up as a file arrives and comes apart as it leaves.
private struct FrameBorder: View, Animatable {
    let style: FrameStyle
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    /// 0 is dots, 1 a solid line.
    var solidness: Double

    @Environment(\.theme) private var theme

    /// CSS `dotted` spaces dots one border-width apart (a 3 pt pitch at 1.5 pt). The pitch is
    /// adjusted per size so the dots close evenly around the corners.
    static let dotPitch: CGFloat = 3

    init(style: FrameStyle, cornerRadius: CGFloat, lineWidth: CGFloat) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        // No outline at all fades as dots, so a file arriving over a screen without one still
        // shows the dots joining as they fade in.
        solidness = style == .dropTarget ? 1 : 0
    }

    var animatableData: Double {
        get { solidness }
        set { solidness = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).inset(by: lineWidth / 2)
            shape.stroke(
                style == .dropTarget ? theme.text : theme.dash,
                style: strokeStyle(length: shape.path(in: CGRect(origin: .zero, size: proxy.size)).measuredLength))
        }
        .opacity(style == .none ? 0 : 1)
        .allowsHitTesting(false)
    }

    private func strokeStyle(length perimeter: CGFloat) -> StrokeStyle {
        guard solidness < 0.999 else { return StrokeStyle(lineWidth: lineWidth) }
        let pitch = perimeter / max(1, (perimeter / Self.dotPitch).rounded())
        // Zero-length dashes with round caps draw dots one line-width across. The caps reach
        // half a line-width past each end, so the gaps close once the dashes are a line-width
        // short of the pitch; growing to that, the gaps narrow evenly all the way to whole.
        let dash = (pitch - lineWidth) * max(0, solidness)
        return StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [dash, pitch - dash])
    }
}

private extension AnyTransition {
    /// Screens trading places (`swap`), the incoming one settling from 98% as the frame springs
    /// to its height. The outgoing screen stops taking up space at once, so the frame heads
    /// straight for the incoming screen's height.
    static func screenSwap(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .swapIn(reduceMotion: reduceMotion, scale: 0.98),
            removal: .swapOut(reduceMotion: reduceMotion).combined(with: .modifier(
                active: LayoutCollapse(isCollapsed: true), identity: LayoutCollapse(isCollapsed: false))))
    }
}

private struct LayoutCollapse: ViewModifier {
    let isCollapsed: Bool

    func body(content: Content) -> some View {
        ZeroHeightLayout(isCollapsed: isCollapsed) { content }
    }
}

/// Reports zero height when collapsed but still draws its content, top-aligned, at full size.
private struct ZeroHeightLayout: Layout {
    let isCollapsed: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        return isCollapsed ? CGSize(width: size.width, height: 0) : size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
    }
}

extension Path {
    /// The path's length, its curves measured as short straight steps: plenty for spacing dots.
    var measuredLength: CGFloat {
        var length: CGFloat = 0
        var start = CGPoint.zero, current = CGPoint.zero
        func walk(_ point: (CGFloat) -> CGPoint) {
            for i in 1...16 {
                let next = point(CGFloat(i) / 16)
                length += hypot(next.x - current.x, next.y - current.y)
                current = next
            }
        }
        forEach { element in
            switch element {
            case .move(let to):
                start = to
                current = to
            case .line(let to):
                let from = current
                walk { t in Self.mix(from, to, t) }
            case .quadCurve(let to, let control):
                let from = current
                walk { t in Self.mix(Self.mix(from, control, t), Self.mix(control, to, t), t) }
            case .curve(let to, let control1, let control2):
                let from = current
                walk { t in
                    let a = Self.mix(from, control1, t), b = Self.mix(control1, control2, t), c = Self.mix(control2, to, t)
                    return Self.mix(Self.mix(a, b, t), Self.mix(b, c, t), t)
                }
            case .closeSubpath:
                let from = current
                walk { t in Self.mix(from, start, t) }
            }
        }
        return length
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
