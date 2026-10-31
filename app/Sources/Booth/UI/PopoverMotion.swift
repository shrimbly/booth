import SwiftUI

/// The popover's animation curves, named after the CSS transitions they port.
enum PopoverMotion {
    /// CSS `ease`: cubic-bezier(0.25, 0.1, 0.25, 1).
    static func ease(_ seconds: Double) -> Animation {
        curve(.cssEase, seconds)
    }

    /// `CubicBezier.easeOut`, the curve for UI answering an action.
    static func easeOut(_ seconds: Double) -> Animation {
        curve(.easeOut, seconds)
    }

    static func curve(_ curve: CubicBezier, _ seconds: Double) -> Animation {
        .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: seconds)
    }

    /// One content dissolving into another (`AnyTransition.swap`), as a single continuous move
    /// with no hard handoff between phases, all on even in-and-out curves:
    /// - what leaves softens from the first frame, and starts to fade at 50 ms while still
    ///   softening;
    /// - what arrives starts at 70 ms, fades in over 280 ms and comes into focus over 320 ms
    ///   from a deeper blur, so it is all there a moment before it is sharp.
    static let swapOutSoften = curve(.inOut, 0.22)
    static let swapOutFade = curve(.inOut, 0.2).delay(0.05)
    static let swapInFade = curve(.inOut, 0.28)
    static let swapInFocus = curve(.inOut, 0.32)
    /// Arriving content's softness, as a multiple of what leaving content softens to.
    static let swapInBlurScale: CGFloat = 1.5
    /// The frame's height follows its content on a smooth spring. A screen change waits for
    /// leaving content's beat to go soft, so nothing is cut off while still clear; a section
    /// opening (Done's Video and Mix) has nothing leaving and grows at once.
    static let sectionOpen = Animation.spring(duration: 0.45, bounce: 0)
    static let screenChange = sectionOpen.delay(0.09)
    static let sectionClose = screenChange
    /// How long the panel keeps its window at the taller of the old and new heights: until the
    /// springs above have settled. The extra window is clear, so erring long costs nothing.
    static let screenChangeSettleSeconds = 0.85
    /// Under Reduce Motion the frame snaps to its new size and only the content cross-fades.
    static let reducedCrossfade = ease(0.15)
    /// The frame's fill and the prompt's colour when a file is dragged over the popover.
    static let dropHover = easeOut(0.2)
    /// The outline's dots joining up into a line (and back): even-paced, so the joining reads.
    static let outlineJoin = ease(0.28)
    /// The signature sharpening under a dragged file: colour 200 ms, blur 260 ms.
    static let signatureInk = ease(0.2)
    static let signatureFocus = ease(0.26)
    /// The focus under the pointer comes in a beat after it arrives, trails it as it moves, and
    /// lingers a moment after it leaves.
    static let pointerFocusIn = ease(0.5).delay(0.15)
    static let pointerFollow = Animation.spring(duration: 0.6, bounce: 0)
    static let pointerFocusOut = ease(0.4)
    /// The switch knob's slight overshoot: cubic-bezier(.3, 1.4, .6, 1) over 220 ms.
    static let switchKnob = Animation.timingCurve(0.3, 1.4, 0.6, 1, duration: 0.22)
    static let switchTrack = ease(0.16)
    /// Progress arrives about four times a second; gliding between updates hides the steps.
    static let progressSeconds = 0.25
    static let progress = Animation.linear(duration: progressSeconds)

    /// `animation`, or nil when the user asked for reduced motion.
    static func unlessReduced(_ animation: Animation, _ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Content in or out of focus, for transitions.
private struct SoftFocus: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// When content arriving in a swap starts.
enum SwapArrival {
    /// In place of content leaving: once that has begun to soften.
    case replacing
    /// Where nothing leaves (a section opening): at once.
    case revealing
    /// Hanging from the frame's bottom edge (a footer): once the frame has nearly reached its
    /// height, so it never rides that edge across the content above it.
    case last

    var delay: Double {
        switch self {
        case .replacing: 0.07
        case .revealing: 0
        case .last: 0.26
        }
    }
}

extension AnyTransition {
    /// Content trading places with what was there (`PopoverMotion.swapOutSoften` and the rest):
    /// a cross-fade that never shows two sharp states on top of each other. Each side carries
    /// its own timing, whatever animates around it. Built from SwiftUI's own blur, opacity and
    /// scale: a transition only animates modifiers SwiftUI knows how to interpolate.
    ///
    /// Under Reduce Motion, when the change around it (`PopoverMotion.unlessReduced`) has no
    /// animation, it is a plain cross-fade: the layout snaps and the content still fades rather
    /// than cutting.
    static func swap(
        reduceMotion: Bool, blur: CGFloat = 4, scale: CGFloat = 1, arriving: SwapArrival = .replacing
    ) -> AnyTransition {
        .asymmetric(
            insertion: swapIn(reduceMotion: reduceMotion, blur: blur, scale: scale, arriving: arriving),
            removal: swapOut(reduceMotion: reduceMotion, blur: blur))
    }

    static func swapIn(
        reduceMotion: Bool, blur: CGFloat = 4, scale: CGFloat = 1, arriving: SwapArrival = .replacing
    ) -> AnyTransition {
        guard !reduceMotion else { return AnyTransition.opacity.animation(PopoverMotion.reducedCrossfade) }
        let focus = PopoverMotion.swapInFocus.delay(arriving.delay)
        var transition = AnyTransition.opacity.animation(PopoverMotion.swapInFade.delay(arriving.delay))
            .combined(with: AnyTransition.modifier(
                active: SoftFocus(radius: blur * PopoverMotion.swapInBlurScale), identity: SoftFocus(radius: 0)
            ).animation(focus))
        if scale != 1 {
            transition = transition.combined(with: AnyTransition.scale(scale: scale, anchor: .top).animation(focus))
        }
        return transition
    }

    static func swapOut(reduceMotion: Bool, blur: CGFloat = 4) -> AnyTransition {
        guard !reduceMotion else { return AnyTransition.opacity.animation(PopoverMotion.reducedCrossfade) }
        return AnyTransition.modifier(active: SoftFocus(radius: blur), identity: SoftFocus(radius: 0))
            .animation(PopoverMotion.swapOutSoften)
            .combined(with: AnyTransition.opacity.animation(PopoverMotion.swapOutFade))
    }
}
