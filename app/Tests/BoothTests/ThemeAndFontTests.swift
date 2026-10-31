import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Booth

@Suite("Theme and fonts")
@MainActor
struct ThemeAndFontTests {
    /// sRGB components 0…255 plus alpha.
    func components(_ color: Color) -> [Double] {
        let resolved = NSColor(color).usingColorSpace(.sRGB)!
        return [resolved.redComponent * 255, resolved.greenComponent * 255, resolved.blueComponent * 255, resolved.alphaComponent]
    }

    func expect(_ color: Color, _ expected: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = components(color)
        let close = zip(actual, expected).allSatisfy { abs($0 - $1) < 0.01 }
        #expect(close, "got \(actual), expected \(expected)", sourceLocation: sourceLocation)
    }

    @Test func spotCheckTokensAgainstTheSpec() {
        expect(Theme.light.glass, [250, 250, 249, 0.82])
        expect(Theme.light.text, [29, 29, 31, 1])
        expect(Theme.light.text2, [60, 60, 67, 0.76])
        expect(Theme.light.dash, [60, 60, 67, 0.38])
        expect(Theme.light.toggleOn, [29, 29, 31, 1])
        expect(Theme.dark.glass, [38, 38, 40, 0.78])
        expect(Theme.dark.text, [245, 245, 247, 1])
        expect(Theme.dark.knob, [236, 236, 238, 1])
        expect(Theme.dark.seg, [255, 255, 255, 0.18])
        expect(Theme.dark.toggleOn, [142, 142, 147, 1])
        expect(Theme.work, [10, 132, 255, 1])
        expect(Theme.light.sig(alpha: 0.4), [60, 60, 67, 0.4])
        expect(Theme.dark.color(for: .over), [245, 245, 247, 0.9])
    }

    @Test func resolvesByColorScheme() {
        expect(Theme.resolve(.dark).inverse, [29, 29, 31, 1])
        expect(Theme.resolve(.light).inverse, [255, 255, 255, 1])
    }

    @Test func spotCheckWorkingBarTokens() {
        expect(Theme.light.ink0, [29, 29, 31, 1])
        expect(Theme.light.onInk, [255, 255, 255, 1])
        expect(Theme.light.inkTrack, [0, 0, 0, 0.07])
        expect(Theme.dark.ink0, [245, 245, 247, 1])
        expect(Theme.dark.onInk, [29, 29, 31, 1])
        expect(Theme.dark.ink3, [142, 142, 147, 1])
    }

    @Test func bundledSignatureFontRegistersUpright() throws {
        #expect(AppResources.url(BundledFonts.signatureFileName) != nil)
        #expect(BundledFonts.registerIfNeeded())
        let font = try #require(BundledFonts.signatureCTFont(size: 44))
        #expect(CTFontCopyFamilyName(font) as String == "Geist Serif")
        #expect(!CTFontGetSymbolicTraits(font).contains(.traitItalic))
    }

    /// The drawn Semibold: seven offset copies widen each letter by the smear and no more.
    @Test func signatureWeightWidensTheOutlineByTheSmear() {
        BundledFonts.registerIfNeeded()
        let size: CGFloat = 44, weight: CGFloat = 0.036
        let regular = SignatureGlyph.make(["o"], size: size, tracking: 0)[0]
        let semibold = SignatureGlyph.make(["o"], size: size, tracking: 0, weight: weight)[0]
        let grown = semibold.outline.boundingRect.width - regular.outline.boundingRect.width
        #expect(abs(grown - weight * size) < 0.01)
        #expect(abs(semibold.outline.boundingRect.height - regular.outline.boundingRect.height) < 0.001)
        #expect(semibold.width == regular.width)
    }
}

@Suite("Path length")
struct PathLengthTests {
    @Test func measuresLinesAndCurves() {
        #expect(abs(Path(CGRect(x: 0, y: 0, width: 100, height: 50)).measuredLength - 300) < 1e-9)
        let circle = Path(ellipseIn: CGRect(x: 0, y: 0, width: 40, height: 40))
        #expect(abs(circle.measuredLength - 40 * .pi) < 0.05)
        // A continuous rounded rectangle is a little shorter than its bounds' perimeter.
        let squircle = RoundedRectangle(cornerRadius: 10, style: .continuous).path(in: CGRect(x: 0, y: 0, width: 300, height: 150))
        #expect(squircle.measuredLength < 900 && squircle.measuredLength > 900 - 8 * 10)
    }
}
