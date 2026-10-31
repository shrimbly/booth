import Testing
@testable import BoothCore

@Suite("Spring curve")
struct SpringCurveTests {
    @Test func startsAtRestAndSettles() {
        let spring = PanelOpening.spring
        #expect(spring.value(at: 0) == 0)
        #expect(spring.value(at: -1) == 0)
        #expect(abs(spring.value(at: 2) - 1) < 1e-4)
        // A 0.12 bounce goes only a hair past its rest.
        let peak = stride(from: 0.0, through: 1, by: 0.002).map(spring.value(at:)).max() ?? 0
        #expect(peak > 1 && peak < 1.03)
    }

    @Test func noBounceIsCriticallyDamped() {
        let spring = SpringCurve(perceptualDuration: 0.4, bounce: 0)
        let samples = stride(from: 0.0, through: 1.5, by: 0.01).map(spring.value(at:))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
        #expect(samples.allSatisfy { $0 <= 1 })
    }
}

@Suite("Panel opening")
struct PanelOpeningTests {
    @Test func opensFromSmallAndLifted() {
        let start = PanelOpening.pose(at: 0)
        #expect(start.scale == PanelOpening.startScale && start.lift == PanelOpening.lift)
        let end = PanelOpening.pose(at: 3)
        #expect(abs(end.scale - 1) < 1e-6 && abs(end.lift) < 1e-4)
    }

    /// Steadied, a point draws exactly where it rests, however far the panel has opened.
    @Test func steadyingCancelsTheDrift() {
        let point = (x: 81.0, y: 141.0), pivot = (x: 304.0, y: 0.0)
        for t in stride(from: 0.0, through: 0.6, by: 0.05) {
            let pose = PanelOpening.pose(at: t)
            let offset = PanelOpening.steadying(point, pivot: pivot, at: t)
            let drawnX = pivot.x + pose.scale * (point.x + offset.x - pivot.x)
            let drawnY = pivot.y + pose.scale * (point.y + offset.y - pivot.y) - pose.lift
            #expect(abs(drawnX - point.x) < 1e-9 && abs(drawnY - point.y) < 1e-9)
        }
    }
}

@Suite("Signature reveal")
struct SignatureRevealTests {
    @Test func startsFarSoftAndUnseen() {
        for letter in SignatureReveal.letters(at: 0, reduceMotion: false) {
            #expect(letter.alpha == 0)
            #expect(abs(letter.scale - 800.0 / 900) < 1e-12)
            #expect(letter.drop == SignatureReveal.rise)
            #expect(abs(letter.extraBlur - (23 - 1.5)) < 1e-12)
        }
        #expect(SignatureReveal.hazeOpacity(at: 0) == 1)
    }

    @Test func settlesToRest() {
        let end = SignatureReveal.seconds
        #expect(abs(end - 0.71) < 1e-9)
        #expect(SignatureReveal.letters(at: end, reduceMotion: false).allSatisfy { $0 == .rest })
        #expect(SignatureReveal.hazeOpacity(at: end) == 0)
    }

    @Test func lettersFollowEachOtherInTurn() {
        let letters = SignatureReveal.letters(at: 0.2, reduceMotion: false)
        for (earlier, later) in zip(letters, letters.dropFirst()) {
            #expect(earlier.alpha > later.alpha)
            #expect(earlier.scale > later.scale)
            #expect(earlier.extraBlur < later.extraBlur)
            #expect(earlier.drop < later.drop)
        }
        // B has started by 60 ms; h hasn't until 160 ms.
        #expect(SignatureReveal.letters(at: 0.06, reduceMotion: false)[0].alpha > 0)
        #expect(SignatureReveal.letters(at: 0.159, reduceMotion: false)[4].alpha == 0)
    }

    @Test func eachLetterOnlyEverComesCloser() {
        var previous = SignatureReveal.letters(at: 0, reduceMotion: false)
        for t in stride(from: 0.01, through: 0.8, by: 0.01) {
            let now = SignatureReveal.letters(at: t, reduceMotion: false)
            for (a, b) in zip(previous, now) {
                #expect(b.alpha >= a.alpha && b.scale >= a.scale && b.extraBlur <= a.extraBlur && b.drop <= a.drop)
            }
            previous = now
        }
    }

    @Test func reducedMotionOnlyClearsAndFades() {
        for t in stride(from: 0.0, through: 0.8, by: 0.05) {
            let still = SignatureReveal.letters(at: t, reduceMotion: true)
            let moving = SignatureReveal.letters(at: t, reduceMotion: false)
            for (a, b) in zip(still, moving) {
                #expect(a.scale == 1 && a.drop == 0)
                #expect(a.alpha == b.alpha && a.extraBlur == b.extraBlur)
            }
        }
    }

    @Test func hazeHoldsThenThins() {
        #expect(SignatureReveal.hazeOpacity(at: 0.1) == 1)
        let samples = stride(from: 0.0, through: 0.8, by: 0.01).map(SignatureReveal.hazeOpacity(at:))
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }
}
