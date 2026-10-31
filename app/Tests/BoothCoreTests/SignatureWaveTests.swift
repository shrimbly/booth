import Testing
@testable import BoothCore

@Suite("Signature wave")
struct SignatureWaveTests {
    func styles(
        _ t: Double, progress: Double = 0, screen: PopoverScreen = .working, drop: Bool = false, reduce: Bool = false
    ) -> [SignatureLetterStyle] {
        SignatureWave.styles(milliseconds: t, progress: progress, screen: screen, dropHover: drop, reduceMotion: reduce)
    }

    @Test func spellsBooth() {
        #expect(String(styles(0).map(\.character)) == "Booth")
    }

    @Test func restingIsSoftFocus() {
        for screen in [PopoverScreen.idle, .done, .settings, .error, .firstrun] {
            for letter in styles(1300, progress: 0.5, screen: screen) {
                #expect(letter.blur == 1.5)
                #expect(letter.ink == .resting(alpha: 0.40))
            }
        }
    }

    @Test func dropHoverSharpensAndInks() {
        for letter in styles(1300, progress: 0.5, screen: .idle, drop: true) {
            #expect(letter.blur == 0)
            #expect(letter.ink == .over)
        }
        // Settings takes no drops.
        #expect(styles(0, screen: .settings, drop: true).allSatisfy { $0.ink == .resting(alpha: 0.40) && $0.blur == 1.5 })
        // The wave stops while a file is over a Working popover.
        #expect(styles(1300, progress: 0.48, drop: true).allSatisfy { $0.ink == .over && $0.blur == 0 })
    }

    /// Reference values computed from the mockup's JavaScript formula.
    @Test func workingWaveAt1300msMatchesTheMockup() {
        let letters = styles(1300, progress: 0.48)
        let expected: [(blur: Double, alpha: Double)] = [
            (0.000057, 0.639987), (0.295315, 0.573637), (0.86082, 0.446557), (1.068, 0.4), (1.068, 0.4),
        ]
        for (letter, reference) in zip(letters, expected) {
            #expect(abs(letter.blur - reference.blur) < 1e-5)
            guard case .resting(let alpha) = letter.ink else {
                Issue.record("expected resting ink")
                continue
            }
            #expect(abs(alpha - reference.alpha) < 1e-5)
        }
    }

    @Test func crestRestsOffstageAtTheEdgesOfTheCycle() {
        let rest = 1.5 * (1 - 0.6 * 0.25)
        for t in [0.0, 4000, 4200, 8400] {
            for letter in styles(t, progress: 0.25) {
                #expect(abs(letter.blur - rest) < 1e-9)
                #expect(letter.ink == .resting(alpha: 0.40))
            }
        }
    }

    @Test func reduceMotionHoldsAStaticBlurScaledByProgress() {
        let letters = styles(1300, progress: 0.5, reduce: true)
        #expect(letters.allSatisfy { abs($0.blur - 1.5 * 0.7) < 1e-12 && $0.ink == .resting(alpha: 0.40) })
    }

    @Test func animatesOnlyWhileWorking() {
        #expect(SignatureWave.isAnimating(screen: .working, dropHover: false, reduceMotion: false))
        #expect(!SignatureWave.isAnimating(screen: .working, dropHover: true, reduceMotion: false))
        #expect(!SignatureWave.isAnimating(screen: .working, dropHover: false, reduceMotion: true))
        #expect(!SignatureWave.isAnimating(screen: .idle, dropHover: false, reduceMotion: false))
    }
}

@Suite("Pointer focus")
struct PointerFocusTests {
    @Test func underThePointerTheNameIsSharperButNeverSharp() {
        let resting = SignatureWave.styles(milliseconds: 0, progress: 0, screen: .idle, dropHover: false, reduceMotion: false)
        for letter in PointerFocus.styles(resting) {
            #expect(letter.blur > 0 && letter.blur < SignatureWave.restingBlur)
            #expect(letter.ink == .resting(alpha: PointerFocus.alpha))
        }
        #expect(PointerFocus.alpha > SignatureWave.restingAlpha)
    }

    @Test func neverBlursOrFadesALetterThatIsAlreadyClearer() {
        let crisp = [SignatureLetterStyle(character: "B", blur: 0.2, ink: .resting(alpha: 0.6))]
        #expect(PointerFocus.styles(crisp) == crisp)
    }

    @Test func aFileOverThePopoverOutranksThePointer() {
        let over = SignatureWave.styles(milliseconds: 0, progress: 0, screen: .idle, dropHover: true, reduceMotion: false)
        #expect(PointerFocus.styles(over) == over)
    }

    @Test func focusEasesOutToTheEdgeOfItsReach() {
        #expect(PointerFocus.amount(atDistance: 0) == 1)
        #expect(abs(PointerFocus.amount(atDistance: PointerFocus.reach / 2) - 0.5) < 1e-12)
        #expect(PointerFocus.amount(atDistance: PointerFocus.reach) == 0)
        #expect(PointerFocus.amount(atDistance: 400) == 0)
        let samples = stride(from: 0.0, through: PointerFocus.reach, by: 0.5).map(PointerFocus.amount(atDistance:))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func maskStopsSpanTheReachAndScaleWithStrength() {
        let full = PointerFocus.stops(strength: 1)
        #expect(full.first?.location == 0 && full.last?.location == 1)
        #expect(full.first?.alpha == 1 && full.last?.alpha == 0)
        for (half, whole) in zip(PointerFocus.stops(strength: 0.5), full) {
            #expect(half.location == whole.location && abs(half.alpha - 0.5 * whole.alpha) < 1e-12)
        }
        #expect(PointerFocus.stops(strength: 0).allSatisfy { $0.alpha == 0 })
    }
}
