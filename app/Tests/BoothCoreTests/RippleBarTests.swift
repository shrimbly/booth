import Foundation
import Testing
@testable import BoothCore

@Suite("Ripple bar")
struct RippleBarTests {
    @Test func ringsStayFaintAndInsideTheFill() {
        for front in [30.0, 120, 200, 295] {
            let fill = RippleBar.fillRadius(front: front)
            for t in stride(from: 0.0, through: 40_000, by: 730) {
                for ring in RippleBar.rings(milliseconds: t, front: front) {
                    #expect(ring.rx > 0.1 && ring.rx < fill - 8)
                    #expect(ring.ry == RippleBar.verticalRadius(ring.rx))
                    #expect(ring.alpha > 0 && ring.alpha <= 0.22)
                    #expect(ring.bandAlpha > 0 && ring.bandAlpha <= 0.06)
                    #expect(ring.lineWidth >= 0.85 && ring.lineWidth <= 1.6)
                }
            }
        }
    }

    @Test func ringsKeepComingButNeverEvenlySpaced() {
        var gaps = Set<Int>()
        for t in stride(from: 2_000.0, through: 60_000, by: 500) {
            let radii = RippleBar.rings(milliseconds: t, front: 200).map(\.rx).sorted()
            #expect(!radii.isEmpty, "no rings at \(t) ms")
            for (a, b) in zip(radii, radii.dropFirst()) { gaps.insert(Int((b - a).rounded())) }
        }
        // Skipped slots and each ring's own moment within its slot vary the spacing.
        #expect(gaps.count > 10)
    }

    @Test func ringsAreRepeatableAndMoveOutward() {
        let now = RippleBar.rings(milliseconds: 15_000, front: 250)
        #expect(now == RippleBar.rings(milliseconds: 15_000, front: 250))
        let later = RippleBar.rings(milliseconds: 15_100, front: 250)
        let common = Set(now.map(\.seed)).intersection(later.map(\.seed))
        #expect(!common.isEmpty)
        for seed in common {
            let a = now.first { $0.seed == seed }!, b = later.first { $0.seed == seed }!
            #expect(abs((b.rx - a.rx) - 100 * RippleBar.ringSpeed) < 1e-9)
        }
    }

    @Test func anEmptyBarHasNoRings() {
        #expect(RippleBar.rings(milliseconds: 9_000, front: 0).isEmpty)
    }

    @Test func theLeadRingFadesAsItRunsAhead() {
        let start = RippleBar.leadRing(milliseconds: 0, front: 100)
        #expect(start.rx == RippleBar.fillRadius(front: 100) + 4)
        #expect(abs(start.alpha - 0.28) < 1e-12)
        let late = RippleBar.leadRing(milliseconds: 1_350, front: 100)
        #expect(late.rx > start.rx && late.alpha < start.alpha)
        #expect(RippleBar.leadRing(milliseconds: RippleBar.leadMilliseconds, front: 100) == start)
    }

    @Test func waverIsSmall() {
        for y in stride(from: -6.0, through: 62, by: 4) {
            #expect(abs(RippleBar.waver(y: y, seed: 31, milliseconds: 5_000)) <= 2.3)
        }
    }

    @Test func speechIsALevel() {
        for u in stride(from: -500.0, through: 5_000, by: 7.3) {
            #expect((0...1).contains(RippleBar.speech(u)))
        }
    }
}

@Suite("Working text")
struct WorkingTextTests {
    @Test func fadesInterpolateAndHoldBeyondTheirEnds() {
        let fade = FrontFade([(-30, 0), (-16, 1), (-4, 1), (8, 0)])
        #expect(fade.alpha(at: -100) == 0)
        #expect(fade.alpha(at: -23) == 0.5)
        #expect(fade.alpha(at: -10) == 1)
        #expect(fade.alpha(at: 2) == 0.5)
        #expect(fade.alpha(at: 50) == 0)
    }

    @Test func stopsStayInsideTheBar() {
        for front in [0.0, 5, 150, 300, 307] {
            for fade in [WorkingText.marks, WorkingText.marksOnFill] + WorkingText.nameLayers.map(\.fade) {
                let stops = fade.stops(front: front, width: 307)
                #expect(stops.first?.location == 0 && stops.last?.location == 1)
                #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location })
                for stop in stops {
                    #expect(abs(stop.alpha - fade.alpha(at: stop.location * 307 - front)) < 1e-12)
                }
            }
        }
    }

    @Test func everyDistanceShowsExactlyOneFullName() {
        for d in stride(from: -80.0, through: 60, by: 0.5) {
            let total = WorkingText.nameLayers.map { $0.fade.alpha(at: d) }.reduce(0, +)
            #expect(abs(total - 1) < 1e-9, "names add to \(total) at \(d)")
            #expect(abs(WorkingText.marks.alpha(at: d) + WorkingText.marksOnFill.alpha(at: d) - 1) < 1e-9)
        }
    }

    @Test func theNameOnlyComesIntoFocusInsideTheFill() {
        // Ahead of the front, and as it crosses, every visible drawing is fully blurred.
        for d in stride(from: -16.0, through: 60, by: 1) {
            for layer in WorkingText.nameLayers where layer.fade.alpha(at: d) > 0 {
                #expect(layer.blur == 2.6, "blur \(layer.blur) at \(d)")
            }
        }
        // Crisp only well inside it.
        let sharp = WorkingText.nameLayers.first { $0.blur == 0 }!
        #expect(sharp.fade.alpha(at: -48) == 1 && sharp.fade.alpha(at: -34) == 0)
    }
}

@Suite("Progress glide")
struct ProgressGlideTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test func eachChangeGlidesInLinearly() {
        var glide = ProgressGlide(seconds: 0.25)
        glide.add(0.2, at: start)
        #expect(abs(glide.value(target: 0.3, at: at(0)) - 0.1) < 1e-12)
        #expect(abs(glide.value(target: 0.3, at: at(0.1)) - 0.18) < 1e-12)
        #expect(glide.value(target: 0.3, at: at(0.25)) == 0.3)
        #expect(glide.value(target: 0.3, at: at(5)) == 0.3)
    }

    @Test func overlappingChangesAddUp() {
        var glide = ProgressGlide(seconds: 0.25)
        glide.add(0.1, at: start)
        glide.add(0.1, at: at(0.1))
        // 0.3 less what is left of each: 0.1 · (1 − 0.8) and 0.1 · (1 − 0.4).
        #expect(abs(glide.value(target: 0.3, at: at(0.2)) - 0.22) < 1e-12)
        #expect(glide.value(target: 0.3, at: at(0.35)) == 0.3)
    }

    @Test func finishedChangesAreForgotten() {
        var glide = ProgressGlide(seconds: 0.25)
        glide.add(0.1, at: start)
        glide.add(0.1, at: at(0.3))
        // Only the second is still gliding.
        #expect(abs(glide.value(target: 0.5, at: at(0.3)) - 0.4) < 1e-12)
        glide.add(0, at: at(1))
        #expect(glide.value(target: 0.5, at: at(0.3)) == 0.5)
    }
}
