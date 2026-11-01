import Foundation

/// SVG's `feTurbulence type="fractalNoise" stitchTiles="stitch"`: a port of the reference
/// implementation in the SVG 1.1 specification (§15.27), so a seed draws the same clouds here as
/// it does in a browser.
struct FractalNoise {
    private static let size = 0x100
    private static let mask = 0xff
    private static let perlinN = 0x1000

    /// A tile of noise: its size in px, and the frequencies and octaves it is drawn at.
    struct Tile {
        let width: Int
        let height: Int
        /// Nudged from the requested ones so a whole number of lattice cells fits the tile and its
        /// edges meet.
        let frequency: SIMD2<Double>
        let octaves: Int

        init(width: Int, height: Int, baseFrequency: (x: Double, y: Double), octaves: Int) {
            self.width = width
            self.height = height
            self.octaves = octaves
            frequency = SIMD2(
                Self.stitched(baseFrequency.x, across: Double(width)), Self.stitched(baseFrequency.y, across: Double(height)))
        }

        private static func stitched(_ frequency: Double, across length: Double) -> Double {
            guard frequency != 0 else { return 0 }
            let low = floor(length * frequency) / length
            let high = ceil(length * frequency) / length
            return frequency / low < high / frequency ? low : high
        }
    }

    /// Lattice cells across and down the tile, and where the lattice wraps back to its start.
    private struct Stitch {
        var width: Int
        var height: Int
        var wrapX: Int
        var wrapY: Int
    }

    private var lattice = [Int](repeating: 0, count: 2 * size + 2)
    /// A unit gradient per lattice point, for each of the four colour channels.
    private var gradients = [[SIMD2<Double>]](repeating: [SIMD2<Double>](repeating: .zero, count: 2 * size + 2), count: 4)

    init(seed: Int) {
        let n = Self.size
        var seed = Self.setupSeed(seed)
        for channel in 0..<4 {
            for i in 0..<n {
                lattice[i] = i
                var gradient = SIMD2<Double>.zero
                for j in 0..<2 {
                    seed = Self.random(seed)
                    gradient[j] = Double(seed % (2 * n) - n) / Double(n)
                }
                let length = (gradient * gradient).sum().squareRoot()
                gradients[channel][i] = length > 0 ? gradient / length : gradient
            }
        }
        for i in stride(from: n - 1, through: 1, by: -1) {
            seed = Self.random(seed)
            lattice.swapAt(i, seed % n)
        }
        for i in 0..<(n + 2) {
            lattice[n + i] = lattice[i]
            for channel in 0..<4 { gradients[channel][n + i] = gradients[channel][i] }
        }
    }

    /// `channel` (0 is red) over the whole tile, at the centre of each px from its top left, row by
    /// row (as Chrome samples it); each value in 0...1.
    func values(of tile: Tile, channel: Int = 0) -> [Double] {
        (0..<tile.height).flatMap { y in
            (0..<tile.width).map { x in value(at: SIMD2(Double(x) + 0.5, Double(y) + 0.5), of: tile, channel: channel) }
        }
    }

    /// `channel` at `point` (px from the tile's top left), in 0...1.
    func value(at point: SIMD2<Double>, of tile: Tile, channel: Int = 0) -> Double {
        let cells = SIMD2(Double(tile.width), Double(tile.height)) * tile.frequency
        var stitch = Stitch(
            width: Int(cells.x + 0.5), height: Int(cells.y + 0.5), wrapX: 0, wrapY: 0)
        stitch.wrapX = Self.perlinN + stitch.width
        stitch.wrapY = Self.perlinN + stitch.height
        var vector = point * tile.frequency
        var sum = 0.0
        var ratio = 1.0
        for _ in 0..<tile.octaves {
            sum += noise(vector, channel: channel, stitch: stitch) / ratio
            vector *= 2
            ratio *= 2
            stitch.width *= 2
            stitch.wrapX = 2 * stitch.wrapX - Self.perlinN
            stitch.height *= 2
            stitch.wrapY = 2 * stitch.wrapY - Self.perlinN
        }
        return min(1, max(0, (sum + 1) / 2))
    }

    private func noise(_ vector: SIMD2<Double>, channel: Int, stitch: Stitch) -> Double {
        let t = vector + Double(Self.perlinN)
        var bx0 = Int(t.x), by0 = Int(t.y)
        var bx1 = bx0 + 1, by1 = by0 + 1
        let rx0 = t.x - Double(Int(t.x)), ry0 = t.y - Double(Int(t.y))
        let rx1 = rx0 - 1, ry1 = ry0 - 1
        if bx0 >= stitch.wrapX { bx0 -= stitch.width }
        if bx1 >= stitch.wrapX { bx1 -= stitch.width }
        if by0 >= stitch.wrapY { by0 -= stitch.height }
        if by1 >= stitch.wrapY { by1 -= stitch.height }
        bx0 &= Self.mask
        bx1 &= Self.mask
        by0 &= Self.mask
        by1 &= Self.mask
        let i = lattice[bx0], j = lattice[bx1]
        let g = gradients[channel]
        let g00 = g[lattice[i + by0]], g10 = g[lattice[j + by0]]
        let g01 = g[lattice[i + by1]], g11 = g[lattice[j + by1]]
        let sx = rx0 * rx0 * (3 - 2 * rx0)
        let sy = ry0 * ry0 * (3 - 2 * ry0)
        let a = Self.lerp(sx, rx0 * g00.x + ry0 * g00.y, rx1 * g10.x + ry0 * g10.y)
        let b = Self.lerp(sx, rx0 * g01.x + ry1 * g01.y, rx1 * g11.x + ry1 * g11.y)
        return Self.lerp(sy, a, b)
    }

    private static func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        a + t * (b - a)
    }

    // The specification's random numbers: Park and Miller's minimal standard generator.
    private static let randM = 2_147_483_647
    private static let randA = 16807
    private static let randQ = 127_773
    private static let randR = 2836

    private static func setupSeed(_ seed: Int) -> Int {
        var seed = seed
        if seed <= 0 { seed = -(seed % (randM - 1)) + 1 }
        return min(seed, randM - 1)
    }

    private static func random(_ seed: Int) -> Int {
        let result = randA * (seed % randQ) - randR * (seed / randQ)
        return result <= 0 ? result + randM : result
    }
}
