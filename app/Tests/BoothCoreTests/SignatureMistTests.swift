import Testing
@testable import BoothCore

@Suite("Signature mist")
struct SignatureMistTests {
    let resting = SignatureWave.styles(milliseconds: 0, progress: 0, screen: .idle, dropHover: false, reduceMotion: false)

    @Test func driftsWhereverTheNameShowsUnlessMotionIsReduced() {
        for screen in PopoverScreen.allCases {
            #expect(SignatureMist.isDrifting(screen: screen, reduceMotion: false) == screen.showsSignature)
            #expect(!SignatureMist.isDrifting(screen: screen, reduceMotion: true))
        }
    }

    /// The website's px, at 56 px for the app's 44 pt.
    @Test func matchesTheWebsite() {
        #expect(abs(SignatureMist.restingBlur - 1.7 * 44 / 56) < 1e-12)
        #expect(abs(SignatureMist.blur - 3.3 * 44 / 56) < 1e-12)
        #expect(SignatureMist.fields.map(\.width) == [320, 260])
        #expect(SignatureMist.fields.map(\.height) == [160, 260])
    }

    @Test func theMistIsSofterAndFainterThanTheRest() {
        for (rest, mist) in zip(SignatureMist.restingStyles(resting), SignatureMist.styles(resting)) {
            #expect(rest.blur < SignatureWave.restingBlur)
            #expect(mist.blur > SignatureWave.restingBlur)
            #expect(rest.ink == .resting(alpha: SignatureWave.restingAlpha))
            #expect(mist.ink == .resting(alpha: 0.37))
        }
    }

    /// Both drawings are the sharp one, so the clouds don't show.
    @Test func aFileOverThePopoverClearsTheMist() {
        let over = SignatureWave.styles(milliseconds: 0, progress: 0, screen: .idle, dropHover: true, reduceMotion: false)
        #expect(SignatureMist.restingStyles(over) == over)
        #expect(SignatureMist.styles(over) == over)
    }

    @Test func eachFieldSlidesWholeTilesInALoop() {
        for field in SignatureMist.fields {
            let size = field.size
            for seconds in [0.0, 1.3, 100, 287.9, 288, 1000] {
                let offset = field.offset(at: seconds)
                #expect(offset.x >= 0 && offset.x < size.width)
                #expect(offset.y >= 0 && offset.y < size.height)
            }
            let start = field.offset(at: 0), end = field.offset(at: SignatureMist.loopSeconds)
            #expect(abs(start.x - end.x) < 1e-9 && abs(start.y - end.y) < 1e-9)
        }
        // A third of a website px a step, as the website moves them.
        let step = SignatureMist.fields[0].offset(at: SignatureMist.stepSeconds).x * 56 / 44
        #expect(abs(step - 1.0 / 3) < 1e-9)
    }

    @Test func cloudsLeaveClearSky() {
        for field in SignatureMist.fields {
            let density = field.density()
            #expect(density.count == field.width * field.height)
            #expect(density.allSatisfy { (0...1).contains($0) })
            #expect(density.contains(0))
            #expect(density.contains { $0 > 0.5 })
        }
    }
}

@Suite("Fractal noise")
struct FractalNoiseTests {
    let tile = FractalNoise.Tile(width: 320, height: 160, baseFrequency: (0.0075, 0.015), octaves: 3)

    /// Two whole lattice cells across and down, the nearest whole numbers to 2.4.
    @Test func stitchingFitsWholeCellsToTheTile() {
        #expect(tile.frequency.x == 2.0 / 320)
        #expect(tile.frequency.y == 2.0 / 160)
    }

    @Test func oppositeEdgesMeet() {
        let noise = FractalNoise(seed: 4)
        for along in stride(from: 0.0, to: 160, by: 13.7) {
            #expect(abs(noise.value(at: SIMD2(0, along), of: tile) - noise.value(at: SIMD2(320, along), of: tile)) < 1e-9)
        }
        for along in stride(from: 0.0, to: 320, by: 17.3) {
            #expect(abs(noise.value(at: SIMD2(along, 0), of: tile) - noise.value(at: SIMD2(along, 160), of: tile)) < 1e-9)
        }
    }

    @Test func aSeedAlwaysDrawsTheSameField() {
        let point = SIMD2(123.5, 45.5)
        #expect(FractalNoise(seed: 4).value(at: point, of: tile) == FractalNoise(seed: 4).value(at: point, of: tile))
        #expect(FractalNoise(seed: 4).value(at: point, of: tile) != FractalNoise(seed: 9).value(at: point, of: tile))
    }

    @Test func valuesStayInRangeAndVary() {
        let values = FractalNoise(seed: 4).values(of: tile)
        #expect(values.count == 320 * 160)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect((values.max() ?? 0) - (values.min() ?? 0) > 0.4)
    }
}
