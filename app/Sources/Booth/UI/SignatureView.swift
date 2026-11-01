import BoothCore
import CoreText
import SwiftUI

/// The "Booth" signature at the frame's bottom left (SPEC §3.4): five Geist Serif letters, each
/// with its own colour and blur. It rests slightly out of focus, with soft clouds of mist drifting
/// through it (`SignatureMist`), and sharpens while a file is over the popover; the pointer on it
/// brings only the letters right around it partly into focus.
///
/// As the popover opens, the name comes forward through fog (`SignatureReveal`), letter by
/// letter, rising into place on screen however the panel moves as it opens.
struct SignatureView: View {
    let screen: PopoverScreen
    let progress: Double
    let dropHover: Bool

    @Environment(\.popoverChrome) private var chrome
    @Environment(\.popoverOpening) private var opening
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// Where the pointer is on the name, or was as it left, so the focus fades out in place.
    @State private var pointer = CGPoint.zero
    @State private var isPointing = false
    /// The name's centre on the glass (`PopoverRootView.glassSpace`), which the panel's opening
    /// moves around and the reveal holds steady.
    @State private var anchor = CGPoint(x: 81, y: 141)
    /// The opening whose reveal has played out, so the clock can stop. A new opening differs at
    /// once, so its reveal starts on its very first frame.
    @State private var settledOpening: Date?

    /// Snapshots freeze the wave here so the PNGs always show the same crest (SPEC §3.9).
    static let snapshotMilliseconds = 1300.0
    /// 46 pt scaled for Geist Serif's larger letters (BoothWeights.dc.html).
    static let fontSize: CGFloat = 44
    /// Semibold: each letter is smeared sideways by this much (in em). Geist Serif ships one
    /// weight; the smear fills out the upright stems and leaves the hairlines fine, the way a
    /// heavier cut of a high-contrast serif would.
    static let weight: CGFloat = 0.036
    /// CSS `letter-spacing: -0.05em` (the link-preview card's), opened by most of the smear so
    /// the spacing holds.
    static let tracking: CGFloat = (-0.05 + 0.7 * weight) * fontSize

    var body: some View {
        Group {
            if chrome == .snapshot {
                letters(at: Self.snapshotMilliseconds)
            } else {
                // Paused rather than removed when still, so the letters keep their identity and
                // the pointer and drop easing still runs. The clouds alone need far fewer frames.
                TimelineView(.animation(
                    minimumInterval: isWaving || isRevealing ? 1.0 / 60 : SignatureMist.stepSeconds,
                    paused: !isWaving && !isRevealing && !isDrifting)
                ) { context in
                    letters(
                        at: context.date.timeIntervalSinceReferenceDate * 1000,
                        reveal: isRevealing ? opening.map { context.date.timeIntervalSince($0.start) } : nil)
                }
            }
        }
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .named(PopoverRootView.glassSpace))
            return CGPoint(x: frame.midX, y: frame.minY + 0.6 * frame.height)
        } action: { anchor = $0 }
        // Stops the clock once this opening's reveal has played out. A name that appears later
        // (back to the drop zone) finds it long over and stays at rest.
        .task(id: opening?.start) {
            guard let start = opening?.start else { return }
            let remaining = start.addingTimeInterval(SignatureReveal.seconds).timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled else { return }
            settledOpening = start
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                // The focus fades in where the pointer arrives, then glides after it.
                withAnimation(isPointing ? PopoverMotion.unlessReduced(PopoverMotion.pointerFollow, reduceMotion) : nil) {
                    pointer = location
                }
                if !isPointing { withAnimation(PopoverMotion.pointerFocusIn) { isPointing = true } }
            case .ended:
                withAnimation(PopoverMotion.pointerFocusOut) { isPointing = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Booth")
        .accessibilityAddTraits(.isHeader)
    }

    private var isWaving: Bool {
        SignatureWave.isAnimating(screen: screen, dropHover: dropHover, reduceMotion: reduceMotion)
    }

    private var isRevealing: Bool {
        guard chrome == .live, let opening else { return false }
        return opening.start != settledOpening
    }

    private var isDrifting: Bool {
        SignatureMist.isDrifting(screen: screen, reduceMotion: reduceMotion)
    }

    /// The letters at `milliseconds` on the wave's clock, `reveal` seconds into the popover's
    /// opening (nil: at rest).
    private func letters(at milliseconds: Double, reveal: Double? = nil) -> some View {
        let styles = SignatureWave.styles(
            milliseconds: milliseconds, progress: progress, screen: screen, dropHover: dropHover, reduceMotion: reduceMotion)
        var parts = Array(repeating: SignatureReveal.Letter.rest, count: styles.count)
        var steadying = CGSize.zero
        var riseScale: CGFloat = 1
        var haze = 0.0
        if let reveal, reveal < SignatureReveal.seconds {
            parts = SignatureReveal.letters(at: reveal, count: styles.count, reduceMotion: reduceMotion)
            haze = SignatureReveal.hazeOpacity(at: reveal)
            // With reduced motion the panel only fades, so there is no drift to cancel.
            if !reduceMotion, let opening {
                let offset = PanelOpening.steadying(
                    (Double(anchor.x), Double(anchor.y)), pivot: (Double(opening.pivotX), 0), at: reveal)
                // In whole pixels: each letter is drawn on the pixel grid, so a fraction of one
                // tips a letter that sits near half a pixel (the first o, at 2×) across as the
                // panel overshoots, and back as it settles.
                steadying = CGSize(width: pixelAligned(offset.x), height: pixelAligned(offset.y))
                riseScale = 1 / PanelOpening.pose(at: reveal).scale
            }
        }
        return PointerFocusView(
            styles: styles, reveal: parts, riseScale: riseScale, clouds: isDrifting ? milliseconds / 1000 : nil,
            pointer: pointer, strength: isPointing ? 1 : 0)
            .offset(steadying)
            .overlay(alignment: .bottomLeading) {
                if haze > 0.001 { SignatureHaze(opacity: haze) }
            }
    }

    private func pixelAligned(_ points: Double) -> CGFloat {
        (CGFloat(points) * displayScale).rounded() / displayScale
    }
}

/// The fog the name comes through: a soft bank of the glass's own colour over the frame's bottom
/// left corner, where the name sits 16 pt in and 2 pt up.
private struct SignatureHaze: View {
    let opacity: Double

    @Environment(\.theme) private var theme

    var body: some View {
        let fog = theme.solidGlass
        Rectangle()
            .fill(EllipticalGradient(
                stops: [
                    .init(color: fog.opacity(SignatureReveal.haze), location: 0),
                    .init(color: fog.opacity(SignatureReveal.haze * 0.63), location: 0.45),
                    .init(color: fog.opacity(0), location: 1),
                ],
                center: UnitPoint(x: 0.45, y: 0.6), startRadiusFraction: 0, endRadiusFraction: 0.5))
            .frame(width: 220, height: 70)
            .blur(radius: SignatureReveal.hazeSoftness)
            .opacity(opacity)
            .offset(x: -16, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The letters drawn twice, at rest and as they look under the pointer, cross-faded by a soft
/// round patch centred on the pointer. With the clouds, a third, mistier drawing shows through
/// them away from the pointer, and the resting drawing gives way there.
private struct PointerFocusView: View, Animatable {
    let styles: [SignatureLetterStyle]
    /// Each letter's part in the reveal; at rest once it has played.
    let reveal: [SignatureReveal.Letter]
    /// Divides the letters' rise, so it measures true on screen while the panel is still small.
    let riseScale: CGFloat
    /// Seconds on the clouds' clock, or nil for none.
    let clouds: Double?
    var pointer: CGPoint
    var strength: Double

    var animatableData: AnimatablePair<CGPoint.AnimatableData, Double> {
        get { AnimatablePair(pointer.animatableData, strength) }
        set {
            pointer.animatableData = newValue.first
            strength = newValue.second
        }
    }

    /// Room around the letters for their blur and smear, so the masks don't clip either. It
    /// grows with the reveal's extra blur and drop, which reach well past the letters.
    private var bleed: CGFloat {
        let extra = reveal.map { 2.5 * $0.extraBlur + $0.drop * Double(riseScale) }.max() ?? 0
        return 8 + CGFloat(extra)
    }

    var body: some View {
        let bleed = bleed
        let glyphs = SignatureGlyph.booth
        let width = glyphs.map(\.width).reduce(0, +) + 2 * bleed
        let height = SignatureView.fontSize + 2 * bleed
        let center = UnitPoint(x: (pointer.x + bleed) / width, y: (pointer.y + bleed) / height)
        let stops = PointerFocus.stops(strength: strength)
        let unfocused = patch(stops.map { ($0.location, 1 - $0.alpha) }, center: center)
        ZStack {
            row(glyphs, clouds == nil ? styles : SignatureMist.restingStyles(styles))
                .padding(bleed)
                .mask(unfocused)
                .mask { SignatureClouds(seconds: clouds, inset: bleed, inverted: true) }
            if clouds != nil {
                row(glyphs, SignatureMist.styles(styles))
                    .padding(bleed)
                    .mask(unfocused)
                    .mask { SignatureClouds(seconds: clouds, inset: bleed, inverted: false) }
                    .blendMode(.plusLighter)
            }
            row(glyphs, PointerFocus.styles(styles))
                .padding(bleed)
                .mask(patch(stops, center: center))
                // Added rather than laid over, so the two drawings cross-fade without a pale seam.
                .blendMode(.plusLighter)
        }
        .compositingGroup()
        .padding(-bleed)
    }

    private func row(_ glyphs: [SignatureGlyph], _ styles: [SignatureLetterStyle]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(glyphs, styles).enumerated()), id: \.offset) { index, letter in
                SignatureLetter(
                    glyph: letter.0, style: letter.1,
                    reveal: index < reveal.count ? reveal[index] : .rest, riseScale: riseScale)
            }
        }
    }

    private func patch(_ stops: [(location: Double, alpha: Double)], center: UnitPoint) -> RadialGradient {
        RadialGradient(
            stops: stops.map { Gradient.Stop(color: .black.opacity($0.alpha), location: $0.location) },
            center: center, startRadius: 0, endRadius: PointerFocus.reach)
    }
}

/// The clouds as a mask: where both fields are, or with `inverted`, everywhere but there (and
/// everywhere without clouds). The letters start `inset` in; the clouds keep their place on the
/// letters however far the drawing's bleed reaches.
private struct SignatureClouds: View {
    let seconds: Double?
    let inset: CGFloat
    let inverted: Bool

    var body: some View {
        Canvas { context, size in
            if inverted { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black)) }
            guard let seconds else { return }
            // Cut out of the solid layer.
            if inverted { context.blendMode = .destinationOut }
            context.drawLayer { clouds in
                for (field, texture) in zip(SignatureMist.fields, CloudTexture.images) {
                    // Without a texture (never, in practice), there are no clouds.
                    guard let image = texture else { return }
                    let tile = field.size
                    let offset = field.offset(at: seconds)
                    // A texture of 2 × 2 tiles drawn from up to a tile before the edge, so one draw
                    // covers anything up to a tile across without a seam.
                    let start = CGPoint(
                        x: (inset + offset.x).truncatingRemainder(dividingBy: tile.width) - tile.width,
                        y: (inset + offset.y).truncatingRemainder(dividingBy: tile.height) - tile.height)
                    for x in stride(from: start.x, to: size.width, by: 2 * tile.width) {
                        for y in stride(from: start.y, to: size.height, by: 2 * tile.height) {
                            clouds.draw(image, in: CGRect(x: x, y: y, width: 2 * tile.width, height: 2 * tile.height))
                        }
                    }
                    // The next field keeps only what lies under this one.
                    clouds.blendMode = .destinationIn
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Each field of cloud as black with the cloud for alpha, 2 × 2 tiles at one px of the website per
/// px. Built on first use.
private enum CloudTexture {
    static let images: [Image?] = SignatureMist.fields.map(image)

    private static func image(of field: SignatureMist.Field) -> Image? {
        let density = field.density()
        let width = 2 * field.width, height = 2 * field.height
        var pixels = [UInt8](repeating: 0, count: 4 * width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[4 * (y * width + x) + 3] = UInt8((255 * density[(y % field.height) * field.width + x % field.width]).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * width,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Image(decorative: image, scale: 1).interpolation(.high)
    }
}

/// One letter's outline, laid out the way CSS sets an inline-block letter with `line-height: 1`.
///
/// Outlines come straight from Core Text so the weight can be drawn: the outline is repeated at
/// seven sideways offsets across `weight` em, the way the mockup stacks `text-shadow` copies.
/// The copies share one path filled with the non-zero rule, so overlaps are inked only once.
struct SignatureGlyph {
    /// In a `width` × font-size box, y down, with the baseline where CSS puts it.
    let outline: Path
    /// The advance plus letter-spacing: the room the letter takes in the row.
    let width: CGFloat

    /// The five letters of "Booth" at the signature size. Built on first use, after launch has
    /// registered the bundled font.
    static let booth = make(
        SignatureWave.letters, size: SignatureView.fontSize, tracking: SignatureView.tracking, weight: SignatureView.weight)

    static func make(_ characters: [Character], size: CGFloat, tracking: CGFloat, weight: CGFloat = 0) -> [SignatureGlyph] {
        let font = BundledFonts.signatureCTFontOrFallback(size: size)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        // CSS centres the font's ascent + descent in the line box.
        let baseline = (size - ascent - descent) / 2 + ascent
        return characters.map { character in
            var units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else {
                return SignatureGlyph(outline: Path(), width: size / 2)
            }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: baseline)
            let single = CTFontCreatePathForGlyph(font, glyphs[0], &flip).map { Path($0) } ?? Path()
            return SignatureGlyph(outline: smeared(single, by: weight * size), width: advance.width + tracking)
        }
    }

    /// `outline` repeated at seven offsets spanning `width` points, centred on the original.
    static func smeared(_ outline: Path, by width: CGFloat) -> Path {
        guard width > 0 else { return outline }
        var path = Path()
        for step in -3...3 {
            path.addPath(outline, transform: CGAffineTransform(translationX: width * CGFloat(step) / 6, y: 0))
        }
        return path
    }
}

private struct SignatureLetter: View {
    let glyph: SignatureGlyph
    let style: SignatureLetterStyle
    let reveal: SignatureReveal.Letter
    let riseScale: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        // Only the drop change eases; the wave and the reveal set new values every frame.
        let isOver = style.ink == .over
        GlyphShape(outline: glyph.outline)
            .fill(theme.color(for: style.ink))
            .animation(PopoverMotion.signatureInk, value: isOver)
            .frame(width: glyph.width, height: SignatureView.fontSize)
            .blur(radius: style.blur + reveal.extraBlur)
            .animation(PopoverMotion.signatureFocus, value: isOver)
            // Further back draws smaller, about the letter's own centre, as through a perspective.
            .scaleEffect(reveal.scale)
            .opacity(reveal.alpha)
            .offset(y: reveal.drop * riseScale)
    }
}

/// A fixed outline drawn at its own coordinates; the weight's smear spills past the frame.
private struct GlyphShape: Shape {
    let outline: Path

    func path(in rect: CGRect) -> Path {
        outline.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
