import Foundation

/// Soft clouds of blur drifting through the resting signature, as through the website's name
/// (site/index.html, which draws the app's 44 pt at 56 px). A third, mistier drawing shows through
/// two fields of cloud that slide past each other, one rolling sideways and one across it, so the
/// clouds swell, part and change shape rather than moving as one; the resting drawing gives way
/// wherever they are. The pointer's patch of focus clears both.
public enum SignatureMist {
    /// The website's px per point.
    static let pixelsPerPoint = 56.0 / 44.0
    /// The resting drawing, between the clouds: a little sharper than without them (1.7 px).
    public static let restingBlur = 1.7 / pixelsPerPoint
    /// The mistier drawing (3.3 px, 37% ink).
    public static let blur = 3.3 / pixelsPerPoint
    public static let alpha = 0.37
    /// One loop of the clouds: four passes of the first field and three of the second.
    public static let loopSeconds = 288.0
    /// The clouds move on 13 times a second, a third of a px at a time: smooth enough for
    /// something this soft, at a fraction of the redrawing.
    public static let stepSeconds = loopSeconds / 3840

    /// A tiling field of fractal noise (`feTurbulence`), its red channel made cloud as alpha
    /// 2.4 r − 0.6.
    public struct Field: Sendable {
        /// The tile, in website px.
        public let width: Int
        public let height: Int
        let baseFrequency: (x: Double, y: Double)
        let octaves: Int
        let seed: Int
        /// How far the field slides in one loop, in website px: whole tiles, so the loop joins up.
        let travel: (x: Double, y: Double)

        /// The tile in points.
        public var size: (width: Double, height: Double) {
            (Double(width) / pixelsPerPoint, Double(height) / pixelsPerPoint)
        }

        /// How far the field has slid `seconds` into the clouds' clock, in points, within one tile.
        public func offset(at seconds: Double) -> (x: Double, y: Double) {
            let loop = seconds.truncatingRemainder(dividingBy: loopSeconds) / loopSeconds
            let size = size
            return (
                Self.wrapped(travel.x * loop / pixelsPerPoint, size.width),
                Self.wrapped(travel.y * loop / pixelsPerPoint, size.height))
        }

        /// The cloud's alpha at each website px of the tile from its top left, row by row.
        public func density() -> [Double] {
            let tile = FractalNoise.Tile(width: width, height: height, baseFrequency: baseFrequency, octaves: octaves)
            return FractalNoise(seed: seed).values(of: tile).map { min(1, max(0, 2.4 * $0 - 0.6)) }
        }

        private static func wrapped(_ value: Double, _ length: Double) -> Double {
            let rest = value.truncatingRemainder(dividingBy: length)
            return rest < 0 ? rest + length : rest
        }
    }

    public static let fields = [
        // Stretched sideways like rolling waves, rolling right.
        Field(width: 320, height: 160, baseFrequency: (0.0075, 0.015), octaves: 3, seed: 4, travel: (1280, 0)),
        // Rounder, drifting across it, down and to the left.
        Field(width: 260, height: 260, baseFrequency: (0.011, 0.011), octaves: 2, seed: 9, travel: (-780, 780)),
    ]

    /// Wherever the name shows, unless motion is reduced.
    public static func isDrifting(screen: PopoverScreen, reduceMotion: Bool) -> Bool {
        screen.showsSignature && !reduceMotion
    }

    /// The resting drawing between the clouds. A file over the popover sharpens the whole name,
    /// and then both drawings are the same, so the clouds don't show.
    public static func restingStyles(_ resting: [SignatureLetterStyle]) -> [SignatureLetterStyle] {
        resting.map { letter in
            guard case .resting = letter.ink else { return letter }
            return SignatureLetterStyle(character: letter.character, blur: restingBlur, ink: letter.ink)
        }
    }

    /// The mistier drawing the clouds show.
    public static func styles(_ resting: [SignatureLetterStyle]) -> [SignatureLetterStyle] {
        resting.map { letter in
            guard case .resting = letter.ink else { return letter }
            return SignatureLetterStyle(character: letter.character, blur: blur, ink: .resting(alpha: alpha))
        }
    }
}
